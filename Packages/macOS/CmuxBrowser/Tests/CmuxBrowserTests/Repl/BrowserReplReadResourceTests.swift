import Foundation
import Testing

@testable import CmuxBrowser

/// r26 native#6: `readResource` was the one native host call outside the
/// host-call bounds: any length of path string reached the bundle lookup
/// on the session's thread, uncharged. It goes through the same host-call
/// path as `fs`, `secrets` and `policy` now: a path over 1,024 bytes is
/// refused before any lookup, and arguments past the host-call limit
/// before they are copied.
@Suite("Browser REPL readResource host call", .serialized)
struct BrowserReplReadResourceTests {
    @Test("readResource refuses a path no resource has, and still reads the guide")
    func readResourceIsBounded() async throws {
        let session = BrowserReplSession(
            id: "read-resource-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: try browserReplRepositoryBundle(),
            driver: ScriptedPageDriver()
        )
        defer { session.close() }

        let result = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: """
            const host = page._session.host;
            for (const path of ["a".repeat(4096), "../".repeat(400) + "etc/hosts"]) {
              try { console.log("read " + typeof host.readResource(path)); } catch (e) { console.log("refused " + e.code); }
            }
            console.log("guide " + typeof host.readResource("guide.md"));
            console.log("missing " + host.readResource("no-such-resource.md"));
            """, timeout: .seconds(30))
        }
        #expect(result?.error == nil, "\(result?.error ?? "no answer")")
        #expect(result?.lines.map(\.text) == ["refused invalid", "refused invalid", "guide string", "missing null"], "\(result?.lines.map(\.text) ?? [])")
    }
}
