public import AppKit

extension NSView {
    /// The view's tooltip, drawn by `TooltipPresenter` in the view's theme (never AppKit's `toolTip`).
    /// It is also the view's accessibility help. Nil or empty: no tooltip.
    public var themedToolTip: String? {
        get { TooltipTracker.existing(for: self)?.text }
        set { TooltipTracker.set(newValue, shortcut: themedToolTipShortcut, on: self) }
    }

    /// The keyboard shortcut shown after the tooltip's text, in the secondary ink ("⌘T").
    public var themedToolTipShortcut: String? {
        get { TooltipTracker.existing(for: self)?.shortcut }
        set { TooltipTracker.set(themedToolTip, shortcut: newValue, on: self) }
    }
}

/// One view's tooltip: its text and the tracking area whose enter and exit reach the presenter.
@MainActor
final class TooltipTracker: NSResponder {
    private static let trackers = NSMapTable<NSView, TooltipTracker>.weakToStrongObjects()

    private(set) weak var view: NSView?
    private(set) var text: String?
    private(set) var shortcut: String?
    private var area: NSTrackingArea?

    static func existing(for view: NSView) -> TooltipTracker? { trackers.object(forKey: view) }

    static func set(_ text: String?, shortcut: String?, on view: NSView) {
        let text = text?.isEmpty == false ? text : nil
        let tracker = existing(for: view) ?? {
            let made = TooltipTracker(view)
            trackers.setObject(made, forKey: view)
            return made
        }()
        tracker.text = text
        tracker.shortcut = shortcut?.isEmpty == false ? shortcut : nil
        view.setAccessibilityHelp(text)
        tracker.track(text != nil)
        TooltipPresenter.shared.changed(tracker)
    }

    private init(_ view: NSView) {
        self.view = view
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Adds the tracking area while there is text, removes it without.
    private func track(_ on: Bool) {
        guard let view else { return }
        if on, area == nil {
            let made = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self, userInfo: nil)
            view.addTrackingArea(made)
            area = made
        } else if !on, let area {
            view.removeTrackingArea(area)
            self.area = nil
            TooltipPresenter.shared.exit(self)
        }
    }

    override func mouseEntered(with event: NSEvent) { TooltipPresenter.shared.enter(self) }
    override func mouseExited(with event: NSEvent) { TooltipPresenter.shared.exit(self) }
}
