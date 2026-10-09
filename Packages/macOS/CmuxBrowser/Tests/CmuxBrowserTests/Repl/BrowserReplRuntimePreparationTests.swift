import Foundation
import Testing

@testable import CmuxBrowser

/// Before macOS 27, JavaScriptCore records no async stack trace, so the
/// runtime's scripts are rewritten (async-owner.js) once per process: a few
/// hundred milliseconds. A session prepares them when it starts, off its
/// cells' clock, so the first cell does not time out for it.
@Suite("Browser REPL runtime preparation")
struct BrowserReplRuntimePreparationTests {
    /// Runtime scripts no session in this process prepared yet stand in
    /// for a fresh process: each gets a comment of its own.
    @Test("A first cell on a runtime no session prepared yet does not pay the preparation under its timeout")
    func aFirstCellDoesNotPayThePreparation() async throws {
        let repository = try browserReplRepositoryBundle()
        let marker = "\n// fresh runtime \(UUID().uuidString)\n"
        let bundle = BrowserReplRuntimeBundle(
            replScripts: repository.replScripts.map { script in
                script.name.hasPrefix("vendor/") ? script : .init(name: script.name, source: script.source + marker)
            },
            agentScripts: repository.agentScripts,
            directory: repository.directory
        )
        let session = BrowserReplSession(
            id: "prepare-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: bundle,
            driver: RecordingReplDriver()
        )
        defer { session.close() }
        let result = await session.evaluate(
            code: "async function answer() { await null; return 41 }\nconsole.log(await answer() + 1)",
            timeout: .milliseconds(200)
        )
        #expect(result.error == nil, "the first cell failed: \(result.error ?? "")")
        #expect(result.lines.map(\.text) == ["42"])
    }
}
