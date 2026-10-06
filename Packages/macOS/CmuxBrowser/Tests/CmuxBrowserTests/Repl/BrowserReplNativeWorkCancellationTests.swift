import Foundation
import Testing

@testable import CmuxBrowser

/// Native work a synchronous host call or a result delivery does on the
/// session's only JavaScript thread (masking text and JSON, parsing a
/// secrets file, Base64) stops between chunks once the watchdog says the
/// cell timed out or the session ended (``BrowserReplWatchdog/shouldStopNativeWork``),
/// since JavaScriptCore's termination cannot reach it.
@Suite("Browser REPL native work cancellation", .serialized)
struct BrowserReplNativeWorkCancellationTests {
    private static let value = "s3cr3t-value-0042"

    private func cancelledBoundary() throws -> BrowserReplBoundary {
        let boundary = BrowserReplBoundary(isCancelled: { true })
        try boundary.secrets.set(name: "key", value: Self.value, domains: ["example.com"], totp: false, title: "t")
        return boundary
    }

    /// One long string, and many short ones (each shorter than a scan's
    /// check interval), in a driver result.
    private static let results: [String] = [
        JSONSerialization.browserReplString(["text": String(repeating: "a", count: 1 << 20)]) ?? "",
        JSONSerialization.browserReplString(["items": Array(repeating: "ab", count: 1 << 18)]) ?? "",
    ]

    @Test("A driver result masked after the cell's deadline ends cancelled", arguments: results.indices)
    func driverResultStops(index: Int) throws {
        let json = Self.results[index]
        let boundary = try cancelledBoundary()
        let egress = boundary.egress(.driverResult(method: "frame.evaluate", .success(json)))
        guard case .failure(let error) = egress.result else {
            Issue.record("the result was delivered: \(egress.size) bytes")
            return
        }
        #expect(error.code == "cancelled", "\(error)")
    }

    @Test("A page event masked after the cell's deadline arrives withheld", arguments: results.indices)
    func eventStops(index: Int) throws {
        let json = Self.results[index]
        let boundary = try cancelledBoundary()
        let delivered = boundary.egress(.event(name: "console", payloadJSON: json, maxBytes: 64 << 20)).text
        #expect(delivered.utf8.count < 1024, "\(delivered.utf8.count) bytes delivered")
        #expect(delivered.contains("withheld"), "\(delivered.prefix(200))")
    }

    @Test("Output text masked after the cell's deadline is withheld")
    func textStops() throws {
        let boundary = try cancelledBoundary()
        let printed = boundary.egress(.text(String(repeating: "a", count: 1 << 20))).text
        #expect(printed.utf8.count < 1024, "\(printed.utf8.count) bytes printed")
    }

    @Test("A host answer masked after the cell's deadline ends cancelled")
    func hostAnswerStops() throws {
        let boundary = try cancelledBoundary()
        let answer = boundary.egress(.host(.success(Array(repeating: "ab", count: 1 << 18)))).text
        let object = JSONSerialization.browserReplObject(answer)
        #expect((object["error"] as? [String: Any])?["code"] as? String == "cancelled", "\(answer.prefix(200))")
    }

    /// `secrets.load` walks every group of the object it is given.
    @Test("secrets.load of a large object after the cell's deadline ends cancelled")
    func secretsLoadStops() throws {
        let boundary = try cancelledBoundary()
        var object: [String: Any] = [:]
        for index in 0..<(1 << 16) { object["d\(index).example.com"] = [String: Any]() }
        guard case .failure(let error) = boundary.secretsOperation("load", ["object": object]) else {
            Issue.record("secrets.load ran to its end")
            return
        }
        #expect(error.code == "cancelled", "\(error)")
    }

    /// One group can hold every secret the store takes; cancellation is
    /// checked between its entries too, and what was loaded before it
    /// stopped is masked.
    @Test("secrets.load stops between the entries of one group once cancelled, masking what it loaded")
    func secretsLoadStopsWithinAGroup() throws {
        let store = BrowserReplSecretStore()
        var group: [String: Any] = [:]
        for index in 0..<200 { group[String(format: "k%03d", index)] = "value-\(index)-s3cr3t" }
        var checks = 0
        // The start and the group pass; the next check is cancelled.
        let cancelled = { () -> Bool in
            checks += 1
            return checks > 3
        }
        #expect(throws: CancellationError.self) { try store.load(["example.com": group], isCancelled: cancelled) }
        let loaded = store.describe().count
        #expect(loaded >= 1 && loaded < 200, "\(loaded) of 200 secrets loaded")
        #expect(store.redact("value-0-s3cr3t") == "<secret:k000>")
    }

    /// A secrets file holds at most 256 values of 4 KiB with their domain
    /// patterns; a larger file is refused before it is parsed, so parsing
    /// (which nothing can stop midway) stays short.
    @Test("secrets.load refuses a file past its size limit before parsing it")
    func secretsLoadRefusesLargeFile() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let groups = (0..<(1 << 19)).map { "\"d\($0).example.com\":{}" }.joined(separator: ",")
        try Data("{\(groups)}".utf8).write(to: work.appendingPathComponent("secrets.json"))
        let session = BrowserReplSession(
            id: "native-\(UUID().uuidString)",
            cwd: work.path,
            bundle: try browserReplRepositoryBundle(),
            driver: ScriptedPageDriver()
        )
        defer { session.close() }
        let result = await browserReplWithDeadline(seconds: 120) {
            await session.evaluate(code: """
            try { await secrets.load("secrets.json"); console.log("loaded"); }
            catch (error) { console.log("refused", error.message); }
            """, timeout: .seconds(60))
        }
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(output.hasPrefix("refused"), "\(output) \(result?.error ?? "")")
        #expect(output.contains("MiB"), "\(output)")
    }

    @Test("Chunked Base64 matches Foundation's and stops when cancelled", arguments: [0, 1, 2, 3, 65_535, 196_608, 196_609, 1 << 20])
    func base64(count: Int) throws {
        let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let encoded = try data.browserReplBase64EncodedString(isCancelled: { false })
        #expect(encoded == data.base64EncodedString())
        #expect(try Data(browserReplBase64: encoded, isCancelled: { false }) == data)
        if count > 1 << 18 {
            #expect(throws: CancellationError.self) { try data.browserReplBase64EncodedString(isCancelled: { true }) }
            #expect(throws: CancellationError.self) { try Data(browserReplBase64: encoded, isCancelled: { true }) }
        }
    }

    @Test("Chunked Base64 refuses what Foundation refuses")
    func base64Invalid() throws {
        let chunk = String(repeating: "QUJD", count: 1 << 16)
        for text in ["QQ", "QQ=", "Q===", "QQ==QUJD", "QUJD\n", chunk.dropLast(1) + "=" + chunk, "*"] {
            #expect(try Data(browserReplBase64: String(text), isCancelled: { false }) == Data(base64Encoded: String(text)), "\(text.prefix(12))")
        }
    }
}
