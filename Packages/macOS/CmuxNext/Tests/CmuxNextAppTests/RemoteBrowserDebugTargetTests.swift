import CmuxNextControl
@testable import CmuxNextApp
import Testing

#if DEBUG
/// SW-08: a debug command's optional remote browser tab must never become
/// another live tab when the requested one closes or several sessions exist.
@Suite @MainActor struct RemoteBrowserDebugTargetTests {
    @Test func aNamedTabSelectsOnlyItself() {
        let sessions = ["tab-agent": 10, "tab-person": 20]
        #expect(RemoteBrowserPages.debugTarget(requested: .string("tab-agent"), in: sessions) == 10)
        #expect(RemoteBrowserPages.debugTarget(requested: .string("tab-person"), in: sessions) == 20)
        #expect(RemoteBrowserPages.debugTarget(requested: .string("tab-closed"), in: sessions) == nil)
    }

    @Test func aMalformedExplicitTabCannotFallBack() {
        let sessions = ["tab-one": 1]
        #expect(RemoteBrowserPages.debugTarget(requested: .string(""), in: sessions) == nil)
        #expect(RemoteBrowserPages.debugTarget(requested: .null, in: sessions) == nil)
        #expect(RemoteBrowserPages.debugTarget(requested: .number(1), in: sessions) == nil)
    }

    @Test func anImplicitTabIsAllowedOnlyWhenUnique() {
        let one = ["tab-one": 1]
        #expect(RemoteBrowserPages.debugTarget(requested: nil, in: one) == 1)
        #expect(RemoteBrowserPages.debugTarget(requested: nil, in: [String: Int]()) == nil)
        #expect(RemoteBrowserPages.debugTarget(requested: nil, in: ["tab-one": 1, "tab-two": 2]) == nil)
    }

    @Test func aStaleRequestedTabCannotBeRedirectedAfterReconnect() {
        let before = ["tab-old": 1]
        let after = ["tab-new": 2]
        #expect(RemoteBrowserPages.debugTarget(requested: .string("tab-old"), in: before) == 1)
        #expect(RemoteBrowserPages.debugTarget(requested: .string("tab-old"), in: after) == nil)
        #expect(RemoteBrowserPages.debugTarget(requested: nil, in: after) == 2)
    }
}
#endif
