import AppKit
@testable import CmuxNextBrowser
import Testing

/// A Chromium tab created in a pane that is not on screen (a background
/// workspace, a tab an agent opens) started at 1280x800 whatever the pane's
/// size, so a responsive page laid out for desktop and reflowed when shown
/// (workspace-proxy-DESIGN.md 9). It starts at the size the pane last showed.
@MainActor @Suite(.serialized) struct CEFPaneHostCreationSizeTests {
    @Test func aLaidOutHostKeepsItsOwnSize() {
        #expect(CEFPaneHost.creationSize(for: NSSize(width: 700, height: 900), lastKnown: NSSize(width: 300, height: 300))
            == NSSize(width: 700, height: 900))
    }

    @Test func aHiddenPaneStartsAtTheSizeItLastShowed() {
        #expect(CEFPaneHost.creationSize(for: .zero, lastKnown: NSSize(width: 640, height: 1010)) == NSSize(width: 640, height: 1010))
    }

    @Test func aPaneNeverShownStartsAtTheHiddenTabViewport() {
        #expect(CEFPaneHost.creationSize(for: .zero, lastKnown: nil) == CEFPaneHost.hiddenTabViewport)
        #expect(CEFPaneHost.creationSize(for: .zero, lastKnown: NSSize(width: 0, height: 500)) == CEFPaneHost.hiddenTabViewport)
    }

    @Test func onlyAnOnScreenLayoutIsRemembered() {
        let pane = BrowserPaneID(rawValue: "pane-creation-size-\(UUID().uuidString)")
        CEFPaneHost.rememberLayout(NSSize(width: 1280, height: 800), pane: pane, inWindow: false)
        #expect(CEFPaneHost.lastLaidOutSize(of: pane) == nil, "the creation frame of an off-screen host is not a pane size")
        CEFPaneHost.rememberLayout(NSSize(width: 812, height: 640), pane: pane, inWindow: true)
        #expect(CEFPaneHost.lastLaidOutSize(of: pane) == NSSize(width: 812, height: 640))
        CEFPaneHost.rememberLayout(.zero, pane: pane, inWindow: true)
        #expect(CEFPaneHost.lastLaidOutSize(of: pane) == NSSize(width: 812, height: 640), "a collapsed frame keeps the last real size")
    }
}
