import AppKit
import CmuxNextActions

/// The window an input event came from, for the length of its dispatch
/// (`WindowManager.dispatching(eventFrom:_:)`).
struct EventOrigin {
    /// The cmux window that owns the event's window, or the window the event's own action made
    /// key since (`eventDidBringForward(_:)`).
    weak var controller: WindowController?
    /// The event's own action made ``controller`` key (``WindowManager/eventDidBringForward(_:)``): it
    /// is the window the rest of the dispatch acts in, ahead of the run's resolved window too.
    var forwarded = false
}

extension WindowManager {
    /// Runs `body`, the dispatch of an input event from `window` (`CmuxApplication.sendEvent`).
    /// While it runs, ``active`` (and the window of an action run it starts, `WindowTarget`) is the
    /// cmux window that owns `window`, whatever window AppKit reports key: a click or key in window A
    /// acts in window A even while the key record names window B (the app activating after Cmd-Tab
    /// makes the window that was key at deactivation key again first; a key change still in flight).
    /// Only a window this app's own code makes key during the dispatch (New Window, Select Next
    /// Window: `WindowActivation.show`) takes over.
    /// A window no cmux window owns leaves ``active`` as it was.
    /// `activates`: the event is one that activates its window for a person (a key-down, a plain left click):
    /// the window is the app's most recently active one from now, also when it never becomes key (the app in
    /// the background, a capture slot). A right-click or a Command-click on a background window brings
    /// nothing forward on macOS (nor a Control-click), so it leaves the app's window order as it is.
    func dispatching<T>(eventFrom window: NSWindow?, activates: Bool = false, _ body: () throws -> T) rethrows -> T {
        let previous = eventOrigin
        defer { eventOrigin = previous }
        if let window, let controller = owner(of: window) {
            eventOrigin = EventOrigin(controller: controller)
            if activates { noteInput(in: controller) }
        }
        return try body()
    }

    /// Whether `event` activates its window for a person (``dispatching(eventFrom:activates:_:)``).
    static func activatesWindow(_ event: NSEvent) -> Bool {
        // A Control-click is a right-click on macOS: like Command-click, it brings no background window forward.
        event.type == .keyDown || (event.type == .leftMouseDown && event.modifierFlags.isDisjoint(with: [.command, .control]))
    }

    /// The window the event in dispatch came from; nil outside an event's dispatch.
    var eventOriginWindow: WindowController? {
        guard let controller = eventOrigin?.controller, controllers.contains(where: { $0 === controller }) else { return nil }
        return controller
    }

    /// `WindowActivation` ordered `window` in front and made it key: during an event's dispatch the
    /// event's action asked for that window, which is the active one from now on.
    func eventDidBringForward(_ window: NSWindow) {
        guard eventOrigin != nil, services.keyWindowSource() === window, let controller = owner(of: window) else { return }
        eventOrigin = EventOrigin(controller: controller, forwarded: true)
    }
}

// The window a command runs against (`WindowTarget`, CmuxNextActions), resolved ONCE at its entrypoint from
// the input itself (multiwindow.md). For action runs, this file is the one place that reads AppKit's window state
// to decide a window (`guardrails.py` implicit-window: `IMPLICIT_WINDOW_RESOLVERS`); the lookups other code still
// makes are counted in implicit-window-baseline.tsv and go in later slices. Everything else gets a window from its
// input: `ActionInvocation.windowID` (set here when the run starts and kept for the run's tasks in
// `ActionRunScope.windowID`), the view's own window, or an explicit argument.

extension WindowManager {
    /// THE resolver: the window an action run acts in, in this order (multiwindow.md 1):
    /// 1. the window the input named (``WindowTarget/Source/named``);
    /// 2. the window of the event in dispatch (keys, clicks, a palette row);
    /// 3. a person's run with no event window (a menu item): the key window now, at the run's start;
    /// 4. the window that owns the run's target workspace or tab (the CLI, MCP, a script);
    /// 5. the window the person used last, as that window recorded it;
    /// 6. the front open window; 7. the launch window awaiting the restore.
    /// Asked once per run by ``ActionRegistry/perform(_:invocation:)`` (``ActionRegistry/windowResolver``).
    func resolveTarget(for invocation: ActionInvocation) -> WindowTarget? {
        if let id = invocation.windowID, isTargetable(id) { return WindowTarget(id: id, source: .named) }
        if let target = invocation.target, target.kind == .window, isTargetable(target.id) {
            return WindowTarget(id: target.id, source: .named)
        }
        if let id = runWindow(), isTargetable(id) { return WindowTarget(id: id, source: .named) }
        if let origin = eventOriginWindow { return WindowTarget(id: origin.state.id, source: .event) }
        if invocation.origin == .user, let key = services.keyWindowSource(), let controller = owner(of: key) {
            return WindowTarget(id: controller.state.id, source: .keyWindowAtEntry)
        }
        if let id = owningWindow(of: invocation) { return WindowTarget(id: id, source: .targetOwner) }
        return ambientTarget()
    }

    /// The window of code that runs with no input of its own (a timer, an observation, a page's
    /// message, a script or socket command with no window): the window of the action run it belongs to,
    /// else the event in dispatch, else the app's most recently active window from its own window order
    /// (also with no key window). Never the key window read at a later time.
    /// A task started in a run keeps the run's window while that window is open (`isTargetable`);
    /// long-lived work (a service loop, an observation) must not start inside a run's scope.
    func ambientTarget() -> WindowTarget? {
        if let origin = eventOrigin, origin.forwarded, let controller = eventOriginWindow {
            return WindowTarget(id: controller.state.id, source: .event)
        }
        if let id = runWindow(), isTargetable(id) { return WindowTarget(id: id, source: .named) }
        if let origin = eventOriginWindow { return WindowTarget(id: origin.state.id, source: .event) }
        // The app's most recently active window from its own window order (Chrome's last active browser
        // window): every key change, order-in and person's key or click updates it. Never the key window read now.
        if let front = registry.value.recency.lazy.compactMap({ self.controller(for: $0) }).first(where: { $0.window != nil }) {
            return WindowTarget(id: front.state.id, source: .appOrder)
        }
        if let lastActive, controllers.contains(where: { $0 === lastActive }) {
            return WindowTarget(id: lastActive.state.id, source: .lastActive)
        }
        if let launch = launchWindowID, awaitsRestore(launch) { return WindowTarget(id: launch, source: .launch) }
        // An unregistered window (the launch window between its build and its registration): the newest.
        return controllers.last.map { WindowTarget(id: $0.state.id, source: .front) }
    }

    /// The window actions without an explicit target act in (``ambientTarget()``'s): inside an action
    /// run the run's own window, resolved once at its entrypoint; during an input event's dispatch
    /// the window the event came from (a click or key in window A acts in window A even while the key
    /// record names window B: the app activating after Cmd-Tab makes the window that was key at
    /// deactivation key again first); else the window the person used last.
    var active: WindowController? {
        ambientTarget().flatMap { controller(for: $0.id) }
    }

    /// The id of the window actions without an explicit target act in (``active``'s). Before the launch
    /// window has a controller (its saved picture shows), the window it stands for.
    var activeWindowID: String? { ambientTarget()?.id }

    /// The window the person is in, for app-wide state only one window publishes (the registry's focus
    /// context, the location trail, the key rule for child windows): the window of the event in
    /// dispatch, else the window that last became key or got the person's key or plain click. Never an action run's
    /// window: a run in window A that brings window B forward makes B the window the person is in.
    var personWindow: WindowController? {
        if let origin = eventOriginWindow { return origin }
        if let lastActive, controllers.contains(where: { $0 === lastActive }) { return lastActive }
        return registry.value.recency.lazy.compactMap { self.controller(for: $0) }.first { $0.window != nil } ?? controllers.last
    }

    /// The app's windows front to back from its own record, never a WindowServer query (audit H6,
    /// H15: `NSApp.orderedWindows` on the input path): a window the registry does not list yet (the
    /// launch window) first, then the registry's recency, which every order-in
    /// (`WindowActivation.didOrder`) and key change (`didActivate`) updates.
    var frontToBack: [WindowController] {
        let recency = registry.value.recency
        let listed = Set(recency)
        let byID = Dictionary(controllers.map { ($0.state.id, $0) }, uniquingKeysWith: { first, _ in first })
        return controllers.filter { !listed.contains($0.state.id) } + recency.compactMap { byID[$0] }
    }

    /// The window a sheet, toast, HUD or panel of the current run or input shows on: the run's window
    /// (``active``), else the front shown cmux window, else (no cmux window open) the key window
    /// (Settings, a standalone panel).
    var presentingWindow: NSWindow? {
        active?.window ?? frontToBack.lazy.compactMap(\.window).first(where: \.isVisible) ?? services.keyWindowSource()
    }

    /// The current action run's window: the window its own code brought forward since it started
    /// (`runDidBringForward`), else the window resolved at its entrypoint. Nil outside a run.
    private func runWindow() -> String? {
        guard let scope = ActionRunScope.current else { return nil }
        if scope.runID != 0, let forwarded = runForwards.last(where: { $0.run == scope.runID })?.window, isTargetable(forwarded) {
            return forwarded
        }
        return scope.windowID
    }

    /// `window` came in front or became key while an action run (or a task it started) runs: the run's
    /// own code asked for it (New Window, Select Next Window, Move to New Window, Reopen), so the run's
    /// later work acts there, as an event's dispatch follows the window its action brought forward.
    /// A person's key change never happens inside a run's task-local scope.
    func runDidBringForward(_ window: NSWindow) {
        guard let scope = ActionRunScope.current, scope.runID != 0, let controller = owner(of: window) else { return }
        runForwards.removeAll { $0.run == scope.runID }
        runForwards.append((scope.runID, controller.state.id))
        if runForwards.count > 32 { runForwards.removeFirst(runForwards.count - 32) }
    }

    /// Installs ``resolveTarget(for:)`` as the registry's window resolver: every action run gets its
    /// window once, at its entrypoint.
    func installTargetResolver() {
        services.registry.windowResolver = { [weak self] invocation in self?.resolveTarget(for: invocation)?.id }
    }

    /// A window a run may act in: open with a controller, or the launch window awaiting the restore.
    private func isTargetable(_ id: String) -> Bool {
        controllers.contains { $0.state.id == id } || awaitsRestore(id)
    }

    /// The open window that lists the workspace the run targets: its `target`, else a `workspace` or
    /// `tab` argument. Both are index lookups (a run never walks the session to find its window); a
    /// pane target's run acts in the person's last window, and its handler finds the pane itself.
    private func owningWindow(of invocation: ActionInvocation) -> String? {
        let arguments = ["workspace", "tab"].compactMap { invocation[$0]?.targetValue }
        for target in [invocation.target].compactMap({ $0 }) + arguments {
            let workspace: String? = switch target.kind {
            case .workspace: target.id
            case .tab: services.workspaceID(ofTab: target.id)
            default: nil
            }
            if let workspace, let owner = registry.value.owner(of: workspace), isTargetable(owner) { return owner }
        }
        return nil
    }
}
