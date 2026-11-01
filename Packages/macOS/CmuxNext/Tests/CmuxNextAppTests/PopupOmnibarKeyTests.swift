import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextPopups
import CmuxNextTestSupport
import Foundation
import Testing

/// The omnibar keys in a popup window, through the real path: the key
/// router decides the key-down (`interceptKeyDown`) with the popup's own
/// binding context. Cmd-L (Focus Location Bar) reaches the popup's omnibar,
/// never the opener's window; Opt-Cmd-F is Search All Windows, never a
/// search in the popup's omnibar; Cmd-W still closes the popup.
@MainActor @Suite(.serialized, .closesItsWindows) struct PopupOmnibarKeyTests {
    private static var timestamp: TimeInterval = 2000

    private struct Harness {
        let services: AppServices
        let tab: MockBrowserTab
        let popup: BrowserPopupWindow
        let opener: NSWindow

        func close() {
            services.popups.closeAll()
            opener.close()
        }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        // The app's action handlers: the key table resolves only runnable actions.
        AppActions.bind(services)
        services.popups.ordersWindowsIn = false
        let opener = NSWindow(contentRect: CGRect(x: 200, y: 100, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        opener.isReleasedWhenClosed = false
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://accounts.example.com/signin")))
        services.popups.open(tab, request: BrowserPopupRequest(size: CGSize(width: 480, height: 360)), from: opener, openerKey: "tab_opener")
        let popup = try #require(services.popups.window(for: tab))
        return Harness(services: services, tab: tab, popup: popup, opener: opener)
    }

    /// A Command key-down in the popup, as AppKit hands it to the router. Whether the router took it.
    private static func press(_ characters: String, keyCode: UInt16, option: Bool = false, in harness: Harness) throws -> Bool {
        timestamp += 1
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: option ? [.command, .option] : [.command],
                                                  timestamp: timestamp, windowNumber: harness.popup.windowNumber, context: nil,
                                                  characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: keyCode))
        return harness.services.keyRouter.interceptKeyDown(event, in: harness.popup)
    }

    @Test func cmdLFocusesThePopupsOmnibar() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        #expect(!harness.popup.addressBar.isEditing)
        #expect(try Self.press("l", keyCode: 37, in: harness), "the router takes Cmd-L in a popup")
        #expect(harness.popup.addressBar.isEditing, "the popup's omnibar has the keyboard")
        #expect(try Self.press("l", keyCode: 37, in: harness), "again while editing: selects the address again")
        #expect(harness.popup.addressBar.isEditing)
    }

    @Test func optCmdFInAPopupIsNotSearchTheWeb() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        _ = try Self.press("f", keyCode: 3, option: true, in: harness)
        #expect(!harness.popup.addressBar.isEditing, "Opt-Cmd-F is Search All Windows; the popup omnibar starts no search")
    }

    @Test func cmdWStillClosesThePopup() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        #expect(try Self.press("w", keyCode: 13, in: harness))
        #expect(!harness.services.popups.owns(harness.tab))
    }
}
