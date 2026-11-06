public import AppKit

/// Whether the person can see a chat's page, so the live capture runs only for a card in sight
/// (``ComputerUseLiveCapture``). Tests pass a fake.
@MainActor
public protocol ComputerUsePreviewSight: AnyObject {
    /// Whether the person can see chat `chat`'s page: in a window, not hidden, the window not
    /// covered or minimized.
    func canSee(_ chat: String) -> Bool
    /// Follows `chats` (the last set is replaced): `changed` runs each time one of them moved into
    /// or out of a window or was hidden or shown. A window that is covered, minimized or shown
    /// again is not followed: the live capture checks ``canSee(_:)`` on each frame and stops, and the
    /// next change of its card starts it again. An empty set follows nothing.
    func follow(_ chats: Set<String>, _ changed: @escaping @MainActor () -> Void)
}

/// ``ComputerUsePreviewSight`` over the chats' views: a zero-size probe in each followed chat's
/// view says when it moved to or out of a window or was hidden or shown (an ancestor too: a tab
/// switch). The app's being active does not count: a window the person can see keeps its live view
/// when another app is in front.
@MainActor
public final class ComputerUsePreviewViewSight: ComputerUsePreviewSight {
    private let view: @MainActor (String) -> NSView?
    private var probes: [String: ComputerUsePreviewSightProbe] = [:]
    private var changed: @MainActor () -> Void = {}

    /// - Parameter view: The view chat `chat`'s page is in; nil when it has none.
    public init(view: @escaping @MainActor (String) -> NSView?) {
        self.view = view
    }

    public func canSee(_ chat: String) -> Bool {
        guard let view = view(chat), let window = view.window else { return false }
        return !view.isHiddenOrHasHiddenAncestor && window.occlusionState.contains(.visible)
    }

    public func follow(_ chats: Set<String>, _ changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        // The probe speaks only once placed: adding or taking it off calls back into no follow.
        for (chat, probe) in probes where !chats.contains(chat) || probe.superview !== view(chat) {
            probe.onChange = nil
            probe.removeFromSuperview()
            probes[chat] = nil
        }
        for chat in chats where probes[chat] == nil {
            guard let view = view(chat) else { continue }
            let probe = ComputerUsePreviewSightProbe(frame: .zero)
            view.addSubview(probe)
            probe.onChange = { [weak self] in self?.changed() }
            probes[chat] = probe
        }
    }
}

/// A zero-size subview that says when its view moved into or out of a window, or was hidden or shown.
@MainActor
final class ComputerUsePreviewSightProbe: NSView {
    var onChange: (@MainActor () -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onChange?()
    }

    override func viewDidHide() {
        super.viewDidHide()
        onChange?()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onChange?()
    }
}
