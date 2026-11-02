import AppKit
import CmuxNextActions
import CmuxNextFocusUI
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Holding the pane-navigation modifier shows, on each pane, the key that moves focus there, and
/// the chips stay up and follow focus while the modifier stays held (user: "Holding Command or
/// Control+Opt needs to show the control one while navigating between the panes"). Every chip
/// reads the window's resolved binding table, so a rebound pane-nav key shows its new key under
/// its new modifier, and a removed one shows nothing ("handle if user has changed default kb shortcut").
@MainActor @Suite(.serialized)
struct PaneNavigationHintTests {
    // MARK: Plan (pure)

    private static func plan(focused: String, neighbors: [PaneNavigationHintPlan<String>.Move: String]) -> PaneNavigationHintPlan<String> {
        PaneNavigationHintPlan(order: ["a", "b", "c"], focused: focused) { neighbors[$0] }
    }

    @Test func eachPaneShowsItsNumberAndTheMoveThatReachesIt() {
        let labels: [ActionID: String] = ["focusLeft": "⌃⌘H", "focusRight": "⌃⌘L"]
        let chips = Self.plan(focused: "b", neighbors: [.left: "a", .right: "c"]).chips { id, digit in
            id == "focusPaneByNumber" ? digit.map { "⌃⌘\($0)" } : labels[id]
        }
        #expect(chips.map(\.pane) == ["a", "b", "c"])
        #expect(chips.map(\.text) == ["⌃⌘1 ⌃⌘H", "⌃⌘2", "⌃⌘3 ⌃⌘L"])
    }

    @Test func unboundMovesShowNoChipAndNextPreviousFollowTheBinding() {
        // Only Focus Next Pane is bound (to a rebound key); no numbers, no directions.
        let chips = Self.plan(focused: "c", neighbors: [.left: "b"]).chips { id, _ in id == "focusNextPane" ? "⌃⌥]" : nil }
        #expect(chips.map(\.pane) == ["a"], "next pane after the last wraps to the first")
        #expect(chips.map(\.text) == ["⌃⌥]"])
    }

    // MARK: Hold policy

    @Test func aPaneNavigationKeyKeepsTheHoldShowing() {
        var policy = ShortcutHintModifierPolicy()
        let held: NSEvent.ModifierFlags = [.control, .option]
        let delay = ShortcutHintModifierPolicy.intentionalHoldDelay
        let shown = policy.update(flags: held, eligible: true, elapsed: delay)
        #expect(shown)
        policy.keyDown(keepsHints: true)
        let kept = policy.update(flags: held, eligible: true, elapsed: delay)
        #expect(kept, "a pane-navigation key hid the hints while the modifier was still held")
        policy.keyDown(keepsHints: false)
        let afterOther = policy.update(flags: held, eligible: true, elapsed: delay)
        #expect(!afterOther, "any other key hides them until release")
    }

    // MARK: Window (real binding table)

    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "hint-ws"), name: "hints", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "hint-ws"), index: 0)])
        return tree
    }

    /// One window with a left/right split, focus on the left pane; returns the right pane's key.
    private static func window() async throws -> (AppServices, WindowController, right: String) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["hint-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
        content.contentView.layoutSubtreeIfNeeded()
        let anyPane = try #require(content.panes.keys.first)
        let screen = try #require(content.layoutModel.screen(containing: anyPane))
        let order = screen.layout.panes
        let left = try #require(content.panes[order[0]]), right = try #require(content.panes[order[1]])
        PaneHandlers.focus(left.layoutPaneID, in: content)
        for _ in 0..<200 where controller.focus.currentState().pane != left.paneKey { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.focus.state.pane == left.paneKey, "the left pane never took focus")
        return (services, controller, right.paneKey)
    }

    private static func chip(on pane: String, _ controller: WindowController, held: NSEvent.ModifierFlags) throws -> String? {
        let hints = try #require(controller.shortcutHints)
        return hints.hints(held: held).first { $0.target == "pane:\(pane)" }?.text
    }

    private static func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func defaultBindingShowsFocusPaneRightOnTheRightPane() async throws {
        let (_, controller, right) = try await Self.window()
        defer { controller.window?.close() }
        let focusRight = Shortcut("l", modifiers: [.control, .command]).displayString
        let text = try Self.chip(on: right, controller, held: [.control, .command])
        #expect(text?.contains(focusRight) == true, "no \(focusRight) chip on the right pane: \(text ?? "none")")
        #expect(controller.shortcutHints?.keepsHints(for: Self.key("l", [.control, .command], code: 37)) == true,
                "\(focusRight) hid the chips instead of keeping them up")
        #expect(controller.shortcutHints?.keepsHints(for: Self.key("t", [.command], code: 17)) == false)
    }

    @Test func reboundPaneNavigationShowsItsNewKeyUnderItsNewModifier() async throws {
        let (services, controller, right) = try await Self.window()
        defer { controller.window?.close() }
        let rebound = Shortcut(Shortcut.rightArrowKey, modifiers: [.control, .option])
        services.registry.setShortcutOverride(rebound, for: "focusRight")
        let text = try Self.chip(on: right, controller, held: [.control, .option])
        #expect(text == rebound.displayString, "holding ⌃⌥ shows \(text ?? "nothing"), not the rebound \(rebound.displayString)")
        let old = Shortcut("l", modifiers: [.control, .command]).displayString
        let underOld = try Self.chip(on: right, controller, held: [.control, .command])
        #expect(underOld?.contains(old) != true, "the old default key still shows")
        let arrow = Self.key(Shortcut.rightArrowKey, [.control, .option, .function, .numericPad], code: 124)
        #expect(controller.shortcutHints?.keepsHints(for: arrow) == true, "the rebound key hid the chips")
        #expect(controller.shortcutHints?.keepsHints(for: Self.key("l", [.control, .command], code: 37)) == false,
                "the old default key still counts as pane navigation")
    }

    @Test func removedPaneNavigationShowsNoChip() async throws {
        let (services, controller, right) = try await Self.window()
        defer { controller.window?.close() }
        services.registry.setShortcutOverride(nil, for: "focusRight")
        let focusRight = Shortcut("l", modifiers: [.control, .command]).displayString
        let text = try Self.chip(on: right, controller, held: [.control, .command])
        #expect(text?.contains(focusRight) != true, "an unbound Focus Pane Right still shows \(focusRight)")
    }
}
