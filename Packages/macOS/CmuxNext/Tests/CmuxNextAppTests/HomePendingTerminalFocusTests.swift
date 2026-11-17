import AppKit
import CmuxHomeCore
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// Ports cp/dogfood-v2-2-12-opt f6646860fad3 and 23248fdeba4a (dogfood v2.2.3, fleet job 2c9383257301002fab1539d7, P0
/// journey `type`; cmux-ad for Lawrence: "terminal input must never reach an agent"). With Home showing, a new terminal
/// was asked for (`newTab` with a terminal) and the keys typed for it went into Home's Chief message box; Return sent the
/// shell command to the Chief as a chat message. Nothing owned the window's keys between the request and the new
/// terminal's keyboard: `newTab` opened no key hold (a split or a new tab in a pane does, `CreationInputCoordinator`),
/// and Home's message box took the keyboard by itself whenever its pane was focused again (`PrimaryInputTarget.landKeyboard`).
/// And automation must never compete with the person (CLAUDE.md, "Go past Chrome where cmux is scripted"): a script's
/// new terminal with focus took the window from a person typing in a text field there.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
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

    /// Automation never competes with the person: a script's new terminal with focus, sent while the person types in a
    /// text input of the window, holds none of their keys and leaves the window where it is; the new workspace is listed,
    /// not shown.
    @Test func aScriptsNewTerminalNeverTakesTheKeysOfAPersonTypingInAField() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let shell = try #require(window.window)
            let host = try #require(shell.contentView)
            // A text field the person put the caret in (typed, so focusing it asks no AutoFill service). Empty: the field
            // is theirs, with a draft or none.
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
            let held = services.keyRouter.creationInputCoordinator.isHolding(in: shell)
            #expect(!held, "a script's new terminal holds the keys of a person typing in a field")
            let typed = try Self.key("x", in: shell)
            let taken = services.keyRouter.interceptKeyDown(typed, in: shell)
            #expect(!taken, "a key the person typed in the field was taken for the script's terminal")

            // The create ran; the workspace is listed in a window and this window stays on Home.
            for task in work { _ = await task.value }
            try await PasswordManagerRouteTests.until({
                services.daemon.store.workspaces.first { $0.name == "scripted-terminal" }.map { services.windows.registry.value.owner(of: $0.id) != nil } == true
            }, report: { "the script's workspace was never listed: \(services.daemon.store.workspaces.map(\.name))" })
            let shown = window.state.workspaceID
            #expect(shown == home.id, "the script's new terminal took the window from the person typing: it shows \(String(describing: shown))")
        }
    }

    /// Control: a script's new terminal with focus shows when no text input has the person's keyboard (the CLI's
    /// `cmux new --focus`): automation waits only for a person typing.
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

    /// Control: the person runs `cmux open <dir>` from another app while cmux sits behind with a text input focused:
    /// their keyboard is not in cmux, so the script's new terminal shows.
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
}
