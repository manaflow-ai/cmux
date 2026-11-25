import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTerminal
import Foundation
import Testing

/// New Browser Tab (Cmd-Shift-L) from a terminal: the new tab's omnibar takes the keyboard at the first frame after the key,
/// while the tab is still its stand-in (Lawrence 2026-11-18: "the time between cmd shift l and when omnibar is focused and i
/// can start typing into it, is still too long"). It used to take it only after the daemon's reply, a round trip later,
/// and the keys typed meanwhile waited in the creation hold. Every key typed right after the shortcut, and after the
/// daemon's tab replaced the stand-in, lands in the omnibar, in order, none lost and none in the terminal.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewBrowserTabOmnibarFocusTests {
    private static let codes: [Character: UInt16] = ["q": 12, "w": 13, "z": 6, "j": 38, "k": 40, "v": 9]

    /// A key-down as `CmuxApplication.sendEvent` delivers it to a window that is not key (the test's).
    private static func press(_ character: Character, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow, router: KeyRouter) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: String(character),
                                           charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: codes[character] ?? 0) else { return }
        if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
    }

    private static func type(_ text: String, in window: NSWindow, router: KeyRouter) {
        for character in text { press(character, in: window, router: router) }
    }

    @Test func theOmnibarTakesTheKeyboardAtTheFirstFrameAndKeepsEveryKeyTypedAfterTheShortcut() async throws {
        // The test's window is never key: a held key runs again into it, as NSApp.sendEvent gives a person's key window.
        try await PasswordManagerRouteTests.withApp(heldKeyReplay: { event, window, _ in window.sendEvent(event) }) { services, _ in
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let router = services.keyRouter
            // On screen, never key: the pane draws its frames (a stand-in's chrome comes after its first frame committed).
            window.orderFrontRegardless()
            if !(window.firstResponder is TerminalSurfaceView) { _ = services.registry.perform("newSurface", invocation: .init(origin: .user)) }
            try await PasswordManagerRouteTests.until({ window.firstResponder is TerminalSurfaceView }, within: .seconds(60),
                                                      report: { "no terminal took the keyboard: \(String(describing: window.firstResponder))" })
            let pane = try #require(controller.focusedPane)
            @MainActor func bar() -> AddressBarView? { if case .browser(let entry)? = pane.currentContent { entry.chrome?.addressBar } else { nil } }
            @MainActor func shows() -> String { "tab \(pane.currentTabKey ?? "none"), content \(pane.currentContent.map { String(describing: $0) } ?? "none"), pages \(services.cache.browsers.keys.sorted())" }

            // New Browser Tab as a person's key runs it, on WebKit: Cmd-Shift-L's own path (PaneBrowserTabOpener's stand-in),
            // with the engine this test process has (no Chromium here, so a Chromium tab never gets a page).
            #expect(services.registry.perform("openBrowser.webkit", invocation: ActionInvocation(origin: .user)))
            // A key typed in the key's own turn, before any frame: the creation hold keeps it for the omnibar.
            Self.type("q", in: window, router: router)
            // The first display frame after the key (the presentation scheduler's show of the selection); no daemon
            // reply could have run yet, so the tab is still its stand-in.
            pane.showSelected()
            let standIn = pane.currentTabKey
            #expect(standIn.map(ProvisionalTab.isProvisional) == true, "the new tab is not its stand-in at the first frame: \(standIn ?? "none")")
            #expect(bar()?.editsAsFirstResponder == true,
                    "the omnibar does not have the keyboard at the first frame after the key (first responder: \(String(describing: window.firstResponder)); \(shows()))")
            Self.type("wz", in: window, router: router)

            // The daemon's tab replaces the stand-in (each poll a frame); the omnibar keeps the keyboard and the keys.
            try await PasswordManagerRouteTests.until({ pane.showSelected(); return pane.currentTabKey.map(ProvisionalTab.isProvisional) == false && bar() != nil },
                                                      within: .seconds(20), report: { "the daemon's tab never replaced the stand-in, or shows no omnibar: \(shows())" })
            Self.type("jkv", in: window, router: router)
            try await PasswordManagerRouteTests.until({ pane.showSelected(); return bar()?.displayedText == "qwzjkv" }, within: .seconds(10),
                                                      report: { "the omnibar shows \(bar()?.displayedText ?? "no omnibar"), not qwzjkv" })
            #expect(bar()?.editsAsFirstResponder == true, "the omnibar lost the keyboard after the daemon's reply")
            #expect(!(window.firstResponder is TerminalSurfaceView), "a terminal has the keyboard")
        }
    }
}
