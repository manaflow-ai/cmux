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

    /// Home shows, the person asks for a new terminal (`newTab`), and until that terminal has the
    /// keyboard Home's message box neither takes the keyboard (its pane focused again by the app) nor gets a typed key.
    @Test func keysTypedForAPersonsNewTerminalOverHomeNeverReachTheChiefMessageBox() async throws {
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

            // The person's new workspace with one terminal (a terminal-first Cmd-N; `command` makes it a terminal, not
            // the New Tab page a person's New Workspace opens by default).
            let request = ActionInvocation(arguments: ["name": .string("pending-terminal"), "command": .string("/bin/sh")], origin: .user)
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

    /// Automation never competes with the person (CLAUDE.md, "Go past Chrome where cmux is scripted"): a script's new
    /// terminal with focus, sent while the person types in a text input of the window, holds none of their keys and
    /// leaves the window where it is; the new workspace is listed, not shown.
    @Test func aScriptsNewTerminalNeverTakesTheKeysOfAPersonTypingInAField() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let shell = try #require(window.window)
            let host = try #require(shell.contentView)
            // A text field the person typed into, with the keyboard (typed, so focusing it asks no AutoFill service).
            // Empty: the person just put the caret there (a draft or none, the field is theirs).
            let field = NSTextField(string: "")
            field.contentType = .URL
            field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
            host.addSubview(field)
            defer { field.removeFromSuperview() }
            let focused = shell.makeFirstResponder(field)
            try #require(focused, "the field did not take the keyboard")
            let editing = shell.firstResponder?.ownsTypedText == true
            try #require(editing, "the field's editor does not have the keyboard: \(String(describing: shell.firstResponder))")
            // The person's keyboard is in this window: the app is active and the window is key (the focus model's facts).
            window.focus.send(.appActive(true))
            window.focus.send(.windowKey(true))

            let request = ActionInvocation(arguments: ["focus": .bool(true), "name": .string("scripted-terminal")], origin: .script)
            var ran = false
            let work = services.registry.capturingWork { ran = services.registry.perform("newTab", invocation: request) }
            #expect(ran)
            let held = services.keyRouter.modes.contains(.creationCapture)
            #expect(!held, "a script's new terminal holds the keys of a person typing in a field")
            let typed = try Self.key("x", in: shell)
            let taken = services.keyRouter.interceptKeyDown(typed, in: shell)
            #expect(!taken, "a key the person typed in the field was taken for the script's terminal")

            // The create and its show decision ran; the workspace is listed in this window and the window stays on Home.
            for task in work { _ = await task.value }
            try await PasswordManagerRouteTests.until({
                services.daemon.store.workspaces.contains { $0.name == "scripted-terminal" }
                    && services.daemon.store.workspaces.first { $0.name == "scripted-terminal" }.map { services.windows.registry.value.owner(of: $0.id) != nil } == true
            }, report: { "the script's workspace was never listed: \(services.daemon.store.workspaces.map(\.name))" })
            let shown = window.state.workspaceID
            #expect(shown == home.id, "the script's new terminal took the window from the person typing: it shows \(String(describing: shown))")
        }
    }

    /// A script's new terminal with focus shows when no text input has the person's keyboard (the CLI's
    /// `cmux new --focus`, `cmux open <dir>` run by a person): automation waits only for a person typing.
    @Test func aScriptsNewTerminalWithFocusShowsWhenNoTextInputHasTheKeyboard() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let shell = try #require(window.window)
            let host = try #require(shell.contentView)
            let holder = Holder(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            host.addSubview(holder)
            defer { holder.removeFromSuperview() }
            let focused = shell.makeFirstResponder(holder)
            try #require(focused, "the test view did not take the keyboard")
            window.focus.send(.appActive(true))
            window.focus.send(.windowKey(true))

            let request = ActionInvocation(arguments: ["focus": .bool(true), "name": .string("shown-terminal")], origin: .script)
            var ran = false
            let work = services.registry.capturingWork { ran = services.registry.perform("newTab", invocation: request) }
            #expect(ran)
            for task in work { _ = await task.value }
            try await PasswordManagerRouteTests.until({
                services.daemon.store.workspaces.first { $0.name == "shown-terminal" }.map { window.state.workspaceID == $0.id } == true
            }, report: {
                "the window shows \(String(describing: window.state.workspaceID)) (Home \(home.id)), workspaces \(services.daemon.store.workspaces.map(\.name))"
            })
        }
    }

    /// The person runs `cmux open <dir>` from another app while cmux sits behind with a text input focused (Home's message
    /// box takes the keyboard by itself): their keyboard is not in cmux, so the script's new terminal shows (review of
    /// 2be9a0cc33a: the text-input check ignored whether the app was active).
    @Test func aScriptsNewTerminalShowsWhenThePersonsKeyboardIsInAnotherApp() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let shell = try #require(window.window)
            let host = try #require(shell.contentView)
            let field = NSTextField(string: "")
            field.contentType = .URL
            field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
            host.addSubview(field)
            defer { field.removeFromSuperview() }
            let focused = shell.makeFirstResponder(field)
            try #require(focused, "the field did not take the keyboard")
            window.focus.send(.appActive(false))

            let request = ActionInvocation(arguments: ["focus": .bool(true), "name": .string("from-another-app")], origin: .cli)
            var ran = false
            let work = services.registry.capturingWork { ran = services.registry.perform("newTab", invocation: request) }
            #expect(ran)
            for task in work { _ = await task.value }
            try await PasswordManagerRouteTests.until({
                services.daemon.store.workspaces.first { $0.name == "from-another-app" }.map { window.state.workspaceID == $0.id } == true
            }, report: {
                "the window shows \(String(describing: window.state.workspaceID)) (Home \(home.id)), workspaces \(services.daemon.store.workspaces.map(\.name))"
            })
        }
    }

    /// A script's run whose handler performs `newTab` with the default (user) invocation and no command: the person's own
    /// newTab opens the New Tab page and its key hold here (the control), the script's nested one opens neither (fourth
    /// review: the spawn and the page hold read the handed invocation's origin).
    @Test func aScriptsNestedNewTabOpensNoNewTabPageHold() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, _) = try await HomeSplitKeysTests.showHome(services, connection)
            let shell = try #require(window.window)
            let input = services.keyRouter.newTabInputCoordinator
            let control = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("persons-page")], origin: .user))
            #expect(control)
            let personHolds = input.isHolding(in: shell)
            try #require(personHolds, "control: the person's own newTab opened no New Tab page hold here")
            // No bound ends a hold any more (lagFirstKey step 3): the control's hold ends here, as a failed open ends it.
            input.cancel(in: shell)
            try #require(!input.isHolding(in: shell), "the person's page hold never ended: \(input.log)")

            let script = ActionRunScope(origin: .script, allowsViewChange: true)
            _ = ActionRunScope.carrying(script) {
                services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("scripts-page")], origin: .user))
            }
            let scriptHolds = input.isHolding(in: shell)
            #expect(!scriptHolds, "a script's nested newTab opened the New Tab page hold: \(input.log)")
        }
    }
}
