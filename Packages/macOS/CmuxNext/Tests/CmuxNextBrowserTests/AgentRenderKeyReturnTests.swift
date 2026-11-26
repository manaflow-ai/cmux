import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Any fork path that activates a parked agent page's window (a show, a creation, a focus) takes the keys from the
/// window the person types in; ``AgentRenderKeyReturn`` gives them back in the same turn.
@MainActor @Suite(.serialized, .closesItsWindows) struct AgentRenderKeyReturnTests {
    @Test func aParkedPageWindowThatBecomesKeyGivesTheKeysBack() throws {
        let typed = Self.window(), render = CEFDeferredFocusTests.renderWindow(), page = Self.window()
        defer { typed.closeAfterTest(); page.closeAfterTest(); render.closeAfterTest() }
        render.addChildWindow(page, ordered: .above)
        typed.orderFrontRegardless()
        let keys = KeyRecorder(key: typed)
        let guardian = AgentRenderKeyReturn(keyWindows: keys.seam)

        guardian.windowBecameKey(typed)
        guardian.windowBecameKey(page)

        #expect(keys.made.map(ObjectIdentifier.init) == [ObjectIdentifier(typed)], "the parked page kept the keys")
    }

    @Test func anOrdinaryWindowThatBecomesKeyKeepsThem() throws {
        let typed = Self.window(), other = Self.window()
        defer { typed.closeAfterTest(); other.closeAfterTest() }
        typed.orderFrontRegardless()
        let keys = KeyRecorder(key: typed)
        let guardian = AgentRenderKeyReturn(keyWindows: keys.seam)

        guardian.windowBecameKey(typed)
        guardian.windowBecameKey(other)

        #expect(keys.made.isEmpty, "a key change between ordinary windows was undone")
    }

    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
    }
}
