public import AppKit
public import CmuxNextInput
import CmuxNextPages
import CmuxNextWakeups

/// A pane that takes the person's key presses and clicks as user gestures (``AgentPaneView``; tests
/// use light views). ``AgentPaneGestureRouter`` finds the one pane an event goes to and calls only it.
@MainActor protocol AgentPaneGestureTarget: NSView {
    /// Judges `event` as this pane's gesture; the pane checks again that it is the person's and its own.
    func judge(_ event: NSEvent, eventWindow: NSWindow?)
    /// The pane's tab in the visibility tree, once the pane that shows it gave one: while it is
    /// hidden the router asks the pane nothing, in O(1). Nil before then. A node that is not hidden
    /// does not prove the pane shows: ``ownsChildWindow(_:)`` still checks.
    var gestureNode: VisibilityNode? { get }
    /// Whether `eventWindow`, a child window of the pane's window, is the window this pane's page
    /// draws in now (a Chromium page draws in such a window, over its pane). A hidden pane owns none:
    /// tabs of one pane keep their pages in the window, hidden, at the same frame.
    func ownsChildWindow(_ eventWindow: NSWindow) -> Bool
}

/// Hands the person's key-downs and mouse-downs to the one agent pane they go to, for its gesture
/// grant (``AgentPaneUserGestures``): one input tap subscription per window that holds an agent pane,
/// not one app-wide monitor per pane, so with 50 panes a press costs one pane's check, not 50.
///
/// The pane is the one the event goes to: for a key, the pane holding the window's first responder;
/// for a click, the pane under the pointer (the window's hit test, so a hidden pane or a view over the
/// page takes nothing); for an event in a child window (a Chromium page's), the shown pane whose page
/// window it is, by identity, not by position, asked only of panes whose tab node is not hidden.
/// Chrome grants user activation the same way, to the frame the event is routed to and to no other
/// (`content/browser/renderer_host/render_widget_host_input_event_router.cc` picks the target widget; `third_party/blink/renderer/core/frame/web_frame_widget_impl.cc` notifies activation for
/// that frame's input only).
///
/// The subscription is an intercept at ``InputEventTap/InterceptOrder/standard`` that always passes,
/// where AppKit's local monitors ran: after the key router, so a key the app's shortcuts take grants
/// nothing, as before. It lives while the window holds a pane.
@MainActor public final class AgentPaneGestureRouter {
    /// The app's input tap (`AppServices.inputTap`); a pane's dictation holds its key-up watch here.
    public let input: InputEventTap

    /// One window's panes and its subscription.
    private final class WindowEntry {
        weak var window: NSWindow?
        var targets: [WeakTarget] = []
        var subscription: InputSubscription?

        init(window: NSWindow) { self.window = window }
    }

    private struct WeakTarget {
        weak var target: (any AgentPaneGestureTarget)?
    }

    private var windows: [WindowEntry] = []
    /// The pane gesture calls made (tests: at most one per press, however many panes).
    private(set) var judgedCount = 0

    /// - Parameter input: The app's input tap (`AppServices.inputTap`).
    public init(input: InputEventTap) { self.input = input }

    /// The windows that have a subscription now (tests).
    var subscribedWindowCount: Int { windows.count(where: { $0.subscription != nil }) }

    /// `target` is in `window` now (it left any other window): its window's subscription hears for it.
    func attach(_ target: any AgentPaneGestureTarget, to window: NSWindow) {
        if let entry = entry(holding: target), entry.window === window { return }
        detach(target)
        let entry = windows.first(where: { $0.window === window }) ?? subscribe(window)
        entry.targets.append(WeakTarget(target: target))
    }

    /// `target` left its window or closed; the window's subscription ends with its last pane.
    func detach(_ target: any AgentPaneGestureTarget) {
        for entry in windows { entry.targets.removeAll { $0.target == nil || $0.target === target } }
        for entry in windows where entry.targets.isEmpty || entry.window == nil { entry.subscription?.cancel() }
        windows.removeAll { $0.targets.isEmpty || $0.window == nil }
    }

    private func entry(holding target: any AgentPaneGestureTarget) -> WindowEntry? {
        windows.first(where: { $0.targets.contains(where: { $0.target === target }) })
    }

    private func subscribe(_ window: NSWindow) -> WindowEntry {
        let entry = WindowEntry(window: window)
        entry.subscription = input.subscribe(class: [.key, .button], phase: .intercept(order: .standard),
                                             window: .window(window)) { [weak self, weak entry] event in
            if let self, let entry { self.route(event, in: entry) }
            return .pass
        }
        windows.append(entry)
        return entry
    }

    private static let presses: InputEventTap.Presses = [.keyDown, .mouseDown]

    private func route(_ event: NSEvent, in entry: WindowEntry) {
        guard Self.presses.matches(event.type), let window = entry.window else { return }
        let eventWindow: NSWindow? = event.windowNumber == window.windowNumber ? window
            : window.childWindows?.first(where: { $0.windowNumber == event.windowNumber })
        guard let eventWindow, let target = target(of: event, eventWindow: eventWindow, in: entry, window: window) else { return }
        judgedCount += 1
        target.judge(event, eventWindow: eventWindow)
    }

    /// The pane `event` goes to, if any.
    private func target(of event: NSEvent, eventWindow: NSWindow, in entry: WindowEntry,
                        window: NSWindow) -> (any AgentPaneGestureTarget)? {
        guard eventWindow === window else {
            for slot in entry.targets {
                guard let target = slot.target, target.gestureNode?.effective != .hidden else { continue }
                if target.ownsChildWindow(eventWindow) { return target }
            }
            return nil
        }
        if event.type == .keyDown { return Self.enclosingTarget(of: window.firstResponder as? NSView) }
        let root = window.contentView?.superview ?? window.contentView
        return Self.enclosingTarget(of: root?.hitTest(event.locationInWindow))
    }

    /// The pane that holds `view`, or nil.
    private static func enclosingTarget(of view: NSView?) -> (any AgentPaneGestureTarget)? {
        var view = view
        while let current = view {
            if let target = current as? any AgentPaneGestureTarget { return target }
            view = current.superview
        }
        return nil
    }
}

extension AgentPaneView: AgentPaneGestureTarget {
    var gestureNode: VisibilityNode? { visibilityNode }

    /// The router asks only while ``gestureNode`` is not hidden. The view tree is still read: a pane's
    /// node does not follow its screen's hiding yet (p06-scheduler-023), and a page window is matched
    /// by place, so a pane on a hidden screen at the same rect must not own the shown pane's window.
    func ownsChildWindow(_ eventWindow: NSWindow) -> Bool { // visibility-walk-allow: one pane per press, after the router's O(1) node skip
        page.showsChromium && !isHiddenOrHasHiddenAncestor && chromiumPage?.isPageWindow(eventWindow) == true
    }
}
