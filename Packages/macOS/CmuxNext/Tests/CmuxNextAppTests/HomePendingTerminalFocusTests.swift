import AppKit
import CmuxHomeCore
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextHome
import CmuxNextTerminal
import Foundation
import Testing

/// Dogfood v2.2.3 (fleet job 2c9383257301002fab1539d7, P0 journey `type`, cmux-ad for Lawrence: "terminal input must
/// never reach an agent"): with Home showing, a script asked for a new terminal (`newTab` with `focus`), the daemon made
/// it, and the keys typed for it went into Home's Chief message box; Enter sent the shell command to the Chief as a chat
/// message. Nothing owned the keys between the request and the new terminal's keyboard: `newTab` opened no key hold (a
/// split or a new tab in a pane does, `CreationInputCoordinator`), so each printable key went to Home's primary input
/// (`KeyRouter.typesIntoPrimaryInput`), and Home's message box took the keyboard by itself whenever its pane was focused
/// again (`PrimaryInputTarget.landKeyboard`) or a conversation showed (`NSWindow.keyboardIsFree(for:)`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HomePendingTerminalFocusTests {
    /// A part of Home that takes the keyboard and no text (as a bubble or the bare transcript does).
    private final class Holder: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private static func key(_ character: Character, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: String(character),
                                      charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0))
    }

    /// Home shows, a script asks for a new terminal with focus (the journey's `newTab`), and until that terminal has the
    /// keyboard Home's message box neither takes the keyboard (its pane focused again by the app) nor gets a typed key.
    @Test func keysTypedForANewTerminalAskedForOverHomeNeverReachTheChiefMessageBox() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let shell = try #require(window.window)
            let dockKey = try #require(window.focusedPane?.paneKey, "Home's dock has no focus")
            // The dock pane's content: Home's page, whose view is the docked Home (Messages, its default view).
            @MainActor func dockView() -> HomeDockView? {
                guard case .page(let view)? = window.content?.paneController(key: dockKey)?.currentContent else { return nil }
                return view.content as? HomeDockView
            }
            try await PasswordManagerRouteTests.until({ dockView()?.messages != nil }, report: {
                "Home's dock pane shows \(String(describing: window.content?.paneController(key: dockKey)?.currentContent)), "
                    + "mode \(String(describing: dockView()?.mode))"
            })
            let page = try #require(dockView()?.messages)
            page.show(ConversationID("conv_pending_terminal"))
            try await PasswordManagerRouteTests.until({ page.host?.primaryInputView is NSTextView }, report: { "Home's message box never appeared" })
            let host = try #require(page.host)
            let box = try #require(host.primaryInputView as? NSTextView)
            // The keyboard is in Home but not in its box (a click on a bubble): the box takes it whenever Home's pane is
            // focused again, which is what the app does by itself at launch and on each topology.
            let holder = Holder(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            host.addSubview(holder)
            defer { holder.removeFromSuperview() }
            @MainActor func state() -> String {
                let focus = window.focus.state
                return "responder \(String(describing: shell.firstResponder)), focus \(focus.resolved.kind) pane \(focus.pane ?? "-") generation \(focus.generation)"
            }

            // Before the request the window's typing keys go straight to the focused view (no owner holds them).
            #expect(!services.keyRouter.modes.contains(.creationCapture), "a key hold was open before the request")
            let holds = shell.makeFirstResponder(holder) && shell.firstResponder === holder
            try #require(holds, "the test view did not take the keyboard")

            // The journey's request: a script's new workspace with one terminal, shown in this window.
            let request = ActionInvocation(arguments: ["focus": .bool(true), "name": .string("pending-terminal")], origin: .script)
            #expect(services.registry.perform("newTab", invocation: request))
            // From this moment the window's keys are the new terminal's: the key router holds them for it, so neither
            // Home's primary input (`typesIntoPrimaryInput`) nor its first responder gets them.
            let held = services.keyRouter.modes.contains(.creationCapture)
            #expect(held, "nothing holds the keys typed for the new terminal: they go to Home (\(state()))")

            // In the same turn, before the daemon made the terminal: the app focuses Home's pane again by itself.
            window.focus.send(.focusPane(dockKey, source: .programmatic))
            let boxTookKeyboard = shell.firstResponder === box
            #expect(!boxTookKeyboard, "Home's message box took the keyboard while a new terminal was pending: \(state())")
            // The keys typed for the new terminal, as the app dispatches them (the router first, then the window).
            var passed: [Character] = []
            for character in "echo ok" {
                let event = try Self.key(character, in: shell)
                if !services.keyRouter.interceptKeyDown(event, in: shell) {
                    passed.append(character)
                    shell.sendEvent(event)
                }
            }
            #expect(passed.isEmpty, "keys typed for the new terminal were not held for it: \(String(passed)), \(state())")
            let boxText = box.string
            #expect(boxText.isEmpty, "keys typed for the new terminal went to Home's message box: \"\(boxText)\", \(state())")

            // The new terminal shows in the window and has the keyboard; the box never got a key.
            try await PasswordManagerRouteTests.until({
                window.state.workspaceID != home.id && shell.firstResponder is TerminalSurfaceView
            }, report: {
                "workspace \(String(describing: window.state.workspaceID)) (Home \(home.id)), responder \(String(describing: shell.firstResponder))"
            })
            let finalText = box.string
            #expect(finalText.isEmpty, "keys typed for the new terminal went to Home's message box: \"\(finalText)\"")
        }
    }
}
