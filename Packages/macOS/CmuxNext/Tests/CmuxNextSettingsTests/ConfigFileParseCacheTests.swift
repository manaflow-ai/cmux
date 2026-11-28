@testable import CmuxNextSettings
import Foundation
import Testing

/// What a settings write's file checks cost at a large `cmux-next.json`, and that the parse cache never returns a
/// document other than a fresh parse of the file's text.
/// Leo 2026-11-27: "maybe we ought to optimize our ds & a for our tooling + whatever stuff wrt the rendering of the app
/// and whatnot". One write reads the document in the controller's plan and again in `CmuxConfigFile.set`/`edit`'s
/// check, the same text: each was a whole-file JSONC parse. Now the second is a compare (`CmuxConfigFile.lastParsed`).
@Suite(.serialized) struct ConfigFileParseCacheTests {
    /// A JSONC settings file of about `kilobytes` KB: comments, nested objects, arrays, every value kind.
    static func text(kilobytes: Int) -> String {
        var out = "// cmux-next.json\n{\n"
        var n = 0
        while out.utf8.count < kilobytes * 1024 {
            out += "  // section \(n)\n  \"s\(n)\": { \"enabled\": \(n % 2 == 0), \"size\": \(n * 3), \"name\": \"row \(n) \\u00e9\","
            out += " \"tags\": [\"a\", \"b\", \(n)], \"nested\": { \"x\": null, \"y\": [ { \"z\": \(Double(n) / 7) } ] } },\n"
            n += 1
        }
        return out + "  \"end\": true\n}\n"
    }

    static func file(_ text: String) throws -> (CmuxConfigFile, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "parse-cache-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (CmuxConfigFile(url: url), url)
    }

    static func stat(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }

    static func microseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1000
    }

    /// A write's two document reads, before (two parses of the file's text) and after (`document()` twice), at 16 KB
    /// and 157 KB (the size of a long-lived settings file): the second read must cost at most a fifth of a parse.
    @Test func secondReadOfOneWriteIsNoParse() async throws {
        for kb in [16, 157] {
            let text = Self.text(kilobytes: kb)
            let (file, url) = try Self.file(text)
            defer { try? FileManager.default.removeItem(at: url) }
            var before: [Double] = [], after: [Double] = [], second: [Double] = [], parse: [Double] = []
            for _ in 0..<30 {
                before.append(try Self.microseconds {
                    _ = try JSONC.parse(CmuxConfigFile.source(at: url)); _ = try JSONC.parse(CmuxConfigFile.source(at: url))
                })
                parse.append(try Self.microseconds { _ = try JSONC.parse(text) })
                // Each write's first read sees new text (the daemon wrote it): forget, then read twice.
                try (text + " ").write(to: url, atomically: true, encoding: .utf8)
                _ = try await file.document()
                try text.write(to: url, atomically: true, encoding: .utf8)
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try await file.document()
                let mid = DispatchTime.now().uptimeNanoseconds
                _ = try await file.document()
                let end = DispatchTime.now().uptimeNanoseconds
                after.append(Double(end &- start) / 1000)
                second.append(Double(end &- mid) / 1000)
            }
            print(String(format: "CONFIG-PARSE-COST kb=%d write-reads before p50=%.0fus p95=%.0fus | after p50=%.0fus p95=%.0fus | second read p50=%.0fus | parse p50=%.0fus",
                         kb, Self.stat(before, 0.5), Self.stat(before, 0.95), Self.stat(after, 0.5), Self.stat(after, 0.95),
                         Self.stat(second, 0.5), Self.stat(parse, 0.5)))
            #expect(Self.stat(second, 0.5) <= Self.stat(parse, 0.5) / 5, "kb=\(kb): a cached read costs \(Self.stat(second, 0.5))us, a parse \(Self.stat(parse, 0.5))us")
        }
    }

    /// Fresh `JSONC.parse` of the file's text is the oracle: across random rewrites (new values, the same text again,
    /// broken text, a removed file) `document()` returns what it returns, or throws when it throws.
    @Test func documentMatchesAFreshParse() async throws {
        let (file, url) = try Self.file("{}")
        defer { try? FileManager.default.removeItem(at: url) }
        var rng = SystemRandomNumberGenerator()
        var texts = ["{}", "{\"a\": 1}", "// c\n{\"a\": 2, \"b\": [true, null]}", "{\"a\": ", "", "{\"a\": 1}\n"]
        for step in 0..<300 {
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: texts.append("{\"k\(step)\": \(Int.random(in: 0..<5, using: &rng))}")
            case 1: try? FileManager.default.removeItem(at: url)
            default: break
            }
            if FileManager.default.fileExists(atPath: url.path) || Bool.random(using: &rng) {
                try texts.randomElement(using: &rng)!.write(to: url, atomically: true, encoding: .utf8)
            }
            let source = try CmuxConfigFile.source(at: url)
            let oracle = try? JSONC.parse(source)
            let got = try? await file.document()
            #expect(got == oracle, "step \(step): \(source.debugDescription)")
        }
    }
}
