import CmuxNextSettings
import Foundation
@testable import CmuxNextPages
import Testing

@MainActor @Suite struct ImportHistoryPageProviderTests {
    private var passive: PageCallContext { PageCallContext(page: "cmux.import-history") }
    private func click(_ event: TimeInterval) -> PageCallContext {
        PageCallContext(page: "cmux.import-history", userGesture: true, gestureEvent: event)
    }

    #if DEBUG
    @Test func debugPickerFixtureCannotEscapeItsFreshHomeThroughASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-picker-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = home.appendingPathComponent("export.zip")
        let outside = root.appendingPathComponent("outside.zip")
        try Data().write(to: inside)
        try Data().write(to: outside)
        #expect(try ImportHistoryPageProvider.debugFixtureZip(inside.path, home: home) == inside.resolvingSymlinksInPath())
        let link = home.appendingPathComponent("escape.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: PageError.self) { try ImportHistoryPageProvider.debugFixtureZip(link.path, home: home) }
        #expect(throws: PageError.self) { try ImportHistoryPageProvider.debugFixtureZip(home.path, home: home) }
    }
    #endif

    @Test func passiveDetectionRejectsArchivesAndExplicitDetectionAdmitsThem() async throws {
        var arguments: [[String]] = []
        let provider = ImportHistoryPageProvider(muxHome: "/test/mux", personOnlyMessage: "Click Import") { args, _ in
            arguments.append(args)
            return ["sources": [["source": "codex", "count": 3, "bytes": 42],
                                ["source": "zip:/not-picked.zip", "count": 1]]]
        }
        let passiveReply = try await provider.call("cmux.importHistory.detect", params: [:], context: passive)
        #expect(!arguments[0].contains("--exports"))
        #expect(passiveReply["sources"]?.arrayValue?.count == 1)
        #expect(passiveReply["sources"]?.arrayValue?.first?["items"] == 3)
        _ = try await provider.call("cmux.importHistory.begin", params: ["batch": "b1"], context: click(1))
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.importHistory.dryRun", params: ["source": "zip:/not-picked.zip", "batch": "b1"], context: passive)
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.importHistory.detect", params: ["exports": .bool(true)], context: passive)
        }
        let explicitReply = try await provider.call(
            "cmux.importHistory.detect",
            params: ["exports": .bool(true)],
            context: click(2)
        )
        #expect(arguments[1].contains("--exports"))
        #expect(explicitReply["sources"]?.arrayValue?.count == 2)
        _ = try await provider.call("cmux.importHistory.dryRun", params: ["source": "zip:/not-picked.zip", "batch": "b1"], context: passive)
        #expect(arguments[2].contains("zip:/not-picked.zip"))
    }

    @Test func pageScriptCannotBeginOrImportWithoutARealClick() async throws {
        var calls = 0
        let provider = ImportHistoryPageProvider(muxHome: "/test/mux", personOnlyMessage: "Click Import") { _, _ in
            calls += 1
            return [:]
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.importHistory.begin", params: ["batch": "b1"], context: passive)
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.importHistory.write", params: ["source": "codex", "batch": "b1"], context: passive)
        }
        #expect(calls == 0)
    }

    @Test func importClickAuthorizesTheAsyncCallsButNeverAnArbitraryPath() async throws {
        var calls: [[String]] = []
        let provider = ImportHistoryPageProvider(muxHome: "/test/mux", personOnlyMessage: "Click Import") { args, _ in
            calls.append(args)
            if args.contains("detect") { return ["sources": [["source": "codex", "count": 3]]] }
            return ["written": 3]
        }
        _ = try await provider.call("cmux.importHistory.detect", params: [:], context: passive)
        _ = try await provider.call("cmux.importHistory.begin", params: ["batch": "b1"], context: click(1))
        _ = try await provider.call("cmux.importHistory.dryRun", params: ["source": "codex", "batch": "b1"], context: passive)
        _ = try await provider.call("cmux.importHistory.write", params: ["source": "codex", "batch": "b1"], context: passive)
        #expect(calls.last?.contains("--stop-host") == true)
        #expect(calls.last?.contains("--batch") == true)
        #expect(calls.last?.contains("b1") == false)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.importHistory.write", params: ["source": "text:/private/file", "batch": "b1"], context: passive)
        }
        #expect(calls.count == 3)
    }

    @Test func finishingRevokesTheGrantAndUndoRequiresItsOwnClick() async throws {
        var finished: Bool?
        var calls = 0
        let provider = ImportHistoryPageProvider(muxHome: "/test/mux", personOnlyMessage: "Click Import") { _, _ in calls += 1; return [:] }
        provider.finish = { finished = $0 }
        _ = try await provider.call("cmux.importHistory.begin", params: ["batch": "b1"], context: click(1))
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.importHistory.undo", params: ["batch": "b1"], context: passive)
        }
        _ = try await provider.call("cmux.importHistory.finish", params: ["completed": false], context: click(2))
        #expect(finished == false)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.importHistory.undo", params: ["batch": "b1"], context: click(3))
        }
        #expect(calls == 0)
    }

    @Test(arguments: ["grok-bot", "muse", "dots", "instinct"])
    func pastedSummaryPassesThroughTheRouterWithItsOriginalOrigin(_ summaryOrigin: String) async throws {
        var commands: [[String]] = []
        let provider = ImportHistoryPageProvider(muxHome: "/test/mux", personOnlyMessage: "Click Import") { args, _ in
            commands.append(args)
            return [:]
        }
        let descriptor = PageDescriptor(id: "cmux.import-history", resource: "import-history", namespaces: ["cmux.importHistory."])
        let router = PageRouter(descriptor: descriptor, routes: [PageRoute(prefix: "cmux.importHistory.", provider: provider)])
        defer { router.close() }
        router.userGestureEvent = { 1 }
        let begun = await router.handle(["t": "call", "id": 1, "op": "cmux.importHistory.begin", "params": ["batch": "b1"]])
        try #require(begun["t"] == "ok")
        router.userGestureEvent = nil
        let reply = await router.handle(["t": "call", "id": 2, "op": "cmux.importHistory.prepareText",
                                         "params": ["summaryOrigin": .string(summaryOrigin), "text": "Prefers tea."]])
        try #require(reply["t"] == "ok")
        let source = try #require(reply["value"]?["source"]?.stringValue)
        #expect(source.hasPrefix("text:"))
        let path = String(source.dropFirst(5))
        let (text, permissions) = try await Task.detached {
            (try String(contentsOfFile: path, encoding: .utf8),
             try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        }.value
        #expect(text == "Prefers tea.")
        #expect(permissions == 0o600)
        let wrongOrigin = summaryOrigin == "muse" ? "instinct" : "muse"
        let rejected = await router.handle(["t": "call", "id": 3, "op": "cmux.importHistory.write",
                                            "params": ["source": .string(source), "summaryOrigin": .string(wrongOrigin), "batch": "b1"]])
        #expect(rejected["t"] == "err")
        #expect(commands.isEmpty)
        for (index, operation) in ["dryRun", "write"].enumerated() {
            let imported = await router.handle(["t": "call", "id": .number(Double(index + 4)),
                                                "op": .string("cmux.importHistory.\(operation)"),
                                                "params": ["source": .string(source), "summaryOrigin": .string(summaryOrigin), "batch": "b1"]])
            #expect(imported["t"] == "ok")
        }
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.suffix(2) == ["--origin", summaryOrigin] })
    }

    @Test func retryKeepsItsNativeBatchSoUndoIncludesEarlierWrites() async throws {
        var writes: [[String]] = []
        let provider = ImportHistoryPageProvider(muxHome: "/test/mux", personOnlyMessage: "Click Import") { args, _ in
            if args.contains("detect") { return ["sources": [["source": "codex", "count": 3]]] }
            writes.append(args)
            return ["written": 1]
        }
        _ = try await provider.call("cmux.importHistory.detect", params: [:], context: passive)
        _ = try await provider.call("cmux.importHistory.begin", params: ["batch": "b1"], context: click(1))
        _ = try await provider.call("cmux.importHistory.write", params: ["source": "codex", "batch": "b1"], context: passive)
        _ = try await provider.call("cmux.importHistory.begin", params: ["batch": "b1"], context: click(2))
        _ = try await provider.call("cmux.importHistory.write", params: ["source": "codex", "batch": "b1"], context: passive)
        #expect(writes.count == 2)
        #expect(writes.first == writes.last)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.importHistory.begin", params: ["batch": "replacement"], context: click(3))
        }
    }

    @Test(arguments: ["write", "undo"])
    func closingThePageLetsItsStartedTransactionFinish(_ verb: String) async throws {
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (held, release) = AsyncStream<Void>.makeStream()
        defer { signalStarted.finish(); release.finish() }
        var completed = false
        var restarts = 0
        let provider = ImportHistoryPageProvider(muxHome: "/test/mux", personOnlyMessage: "Click Import") { args, _ in
            if args.contains("detect") { return ["sources": [["source": "codex", "count": 1]]] }
            signalStarted.yield(())
            for await _ in held { break }
            try Task.checkCancellation()
            completed = true
            return ["written": 1]
        }
        provider.restart = { restarts += 1 }
        _ = try await provider.call("cmux.importHistory.detect", params: [:], context: passive)
        _ = try await provider.call("cmux.importHistory.begin", params: ["batch": "b1"], context: click(1))
        let requestContext = verb == "undo" ? click(2) : passive
        let request = Task { @MainActor in
            try await provider.call("cmux.importHistory." + verb, params: ["source": "codex", "batch": "b1"], context: requestContext)
        }
        var events = started.makeAsyncIterator()
        _ = await events.next()
        // PageRouter.close cancels its in-flight request after Skip closes the page.
        _ = try await provider.call("cmux.importHistory.finish", params: ["completed": false], context: click(3))
        request.cancel()
        release.yield(())
        _ = try await request.value
        #expect(completed)
        #expect(restarts == 1)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.importHistory.write", params: ["source": "codex", "batch": "b1"], context: passive)
        }
    }
}
