import CmuxNextPages
import CmuxNextSettings
import Testing
@testable import CmuxNextApp

/// The remote inspector page's one op: only the seven API paths reach the
/// brain's daemon; anything else is refused in the app first.
@Suite struct ChiefInspectorPageProviderTests {
    @Test @MainActor func refusesOtherOpsAndPathsBeforeTheDaemon() async throws {
        var asked = 0
        let provider = ChiefInspectorPageProvider { asked += 1; return nil }
        let context = PageCallContext(page: "cmux.chief-inspector")
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.chief_inspector.write", params: ["path": "/api/status"], context: context)
        }
        for path in ["/", "/api/ticket", "/index.html", "/api/../x"] {
            await #expect(throws: PageError.self) {
                _ = try await provider.call(ChiefInspectorPageProvider.get, params: ["path": .string(path)], context: context)
            }
        }
        #expect(asked == 0, "no refused call looked for a daemon")
        // An allowed path with no connected server: unavailable, not a crash.
        await #expect(throws: PageError.self) {
            _ = try await provider.call(ChiefInspectorPageProvider.get, params: ["path": "/api/status"], context: context)
        }
        #expect(asked == 1)
        #expect(ChiefInspectorPageProvider.paths.count == 7)
    }
}
