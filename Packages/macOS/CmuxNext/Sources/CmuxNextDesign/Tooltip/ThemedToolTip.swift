public import AppKit

extension NSView {
    /// The view's tooltip, drawn by `TooltipPresenter` in the view's theme (never AppKit's `toolTip`).
    /// It is also the view's accessibility help. Nil or empty: no tooltip.
    public var themedToolTip: String? {
        get { TooltipTracker.whole(of: self)?.text }
        set { TooltipTracker.setWhole(newValue, shortcut: themedToolTipShortcut, on: self) }
    }

    /// The keyboard shortcut shown after the tooltip's text, in the secondary ink ("⌘T").
    public var themedToolTipShortcut: String? {
        get { TooltipTracker.whole(of: self)?.shortcut }
        set { TooltipTracker.setWhole(themedToolTip, shortcut: newValue, on: self) }
    }

    /// Tooltips for parts of the view (AppKit's `addToolTip(_:owner:userData:)`), in its coordinates;
    /// replaces the previous ones. A region wins over the view's own tooltip.
    public func setThemedToolTipRegions(_ regions: [(rect: NSRect, text: String)]) {
        TooltipTracker.setRegions(regions, on: self)
    }

    /// For a view that is hidden most of the time (a row's hover-only buttons): its tooltip's text and shortcut are
    /// kept and read back at once, but the hover tracking area is added only once the view can show (in a window,
    /// not hidden); the view calls ``themedToolTipCanShow()`` when it shows. Off: tracking starts with the text.
    public var defersThemedToolTipTracking: Bool {
        get { TooltipTracker.defers(self) }
        set { TooltipTracker.setDefers(newValue, on: self) }
    }

    /// A view with ``defersThemedToolTipTracking`` calls this when it shows (`viewDidUnhide`, `viewDidMoveToWindow`):
    /// its tooltip's tracking area is added then.
    public func themedToolTipCanShow() {
        TooltipTracker.whole(of: self)?.trackIfShown()
    }
}

/// One tooltip of a view, the whole view or a region of it, with the tracking area whose enter and
/// exit reach the presenter.
@MainActor
final class TooltipTracker: NSResponder {
    private static let trackers = NSMapTable<NSView, TrackerSet>.weakToStrongObjects()

    private(set) weak var view: NSView?
    /// The region in the view's coordinates; nil: the whole view.
    let region: NSRect?
    private(set) var text: String?
    private(set) var shortcut: String?
    private var area: NSTrackingArea?
    /// Tracking without an area of its own: a layout screen's one pointer area tells the presenter (``PanePointerTargets``).
    private(set) var isServed = false

    static func whole(of view: NSView) -> TooltipTracker? { trackers.object(forKey: view)?.whole }

    /// The trackers of `view` that the screen's pointer area serves now.
    static func served(of view: NSView) -> [TooltipTracker] { all(of: view).filter(\.isServed) }

    /// `view` sits in a layout screen: its tracking trackers give up their areas; the screen's area serves them.
    static func adoptServed(_ view: NSView) {
        for tracker in all(of: view) {
            guard let area = tracker.area else { continue }
            view.removeTrackingArea(area)
            tracker.area = nil
            tracker.isServed = true
        }
    }

    /// Whether `windowPoint` is over this tooltip's view or region now.
    func contains(_ windowPoint: NSPoint) -> Bool {
        guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
        let local = (region ?? view.bounds).intersection(view.visibleRect)
        return local.contains(view.convert(windowPoint, from: nil))
    }

    /// The trackers of `view` (tests).
    static func all(of view: NSView) -> [TooltipTracker] {
        guard let set = trackers.object(forKey: view) else { return [] }
        return (set.whole.map { [$0] } ?? []) + set.regions
    }

    static func setWhole(_ text: String?, shortcut: String?, on view: NSView) {
        let text = text?.isEmpty == false ? text : nil
        let existing = whole(of: view)
        guard existing != nil || text != nil else { return }
        let tracker = existing ?? TooltipTracker(view, region: nil)
        if existing == nil { set(of: view).whole = tracker }
        tracker.text = text
        tracker.shortcut = shortcut?.isEmpty == false ? shortcut : nil
        view.setAccessibilityHelp(text)
        tracker.track(text != nil && !(set(of: view).defers && !canShow(view)))
        TooltipPresenter.shared.changed(tracker)
    }

    static func setRegions(_ regions: [(rect: NSRect, text: String)], on view: NSView) {
        let set = set(of: view)
        for old in set.regions { old.track(false) }
        set.regions = regions.filter { !$0.text.isEmpty }.map { region in
            let tracker = TooltipTracker(view, region: region.rect)
            tracker.text = region.text
            tracker.track(true)
            return tracker
        }
    }

    static func defers(_ view: NSView) -> Bool { trackers.object(forKey: view)?.defers ?? false }

    static func setDefers(_ defers: Bool, on view: NSView) {
        guard defers != self.defers(view) else { return }
        set(of: view).defers = defers
        whole(of: view)?.trackIfShown()
    }

    /// The view can be hovered: in a window and not hidden.
    private static func canShow(_ view: NSView) -> Bool { view.window != nil && !view.isHiddenOrHasHiddenAncestor }

    /// Adds the tracking area while there is text and the view can show (or does not defer).
    func trackIfShown() {
        guard let view else { return }
        track(text != nil && !(Self.defers(view) && !Self.canShow(view)))
    }

    private static func set(of view: NSView) -> TrackerSet {
        if let set = trackers.object(forKey: view) { return set }
        let made = TrackerSet()
        trackers.setObject(made, forKey: view)
        return made
    }

    private init(_ view: NSView, region: NSRect?) {
        self.view = view
        self.region = region
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// How deep the tooltip sits: the view's ancestors, one more for a region. The deepest one
    /// under the pointer shows, as AppKit picks the innermost view.
    var depth: Int {
        var count = region == nil ? 0 : 1
        var current = view?.superview
        while let next = current {
            count += 1
            current = next.superview
        }
        return count
    }

    /// The tooltip's anchor in screen coordinates: the visible part of the view or region.
    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        let local = (region ?? view.bounds).intersection(view.visibleRect)
        guard !local.isEmpty else { return nil }
        return window.convertToScreen(view.convert(local, to: nil))
    }

    /// The view's own visible label already says the tooltip's text (a titled button, a label):
    /// no tooltip, as #20375 rules for pages (webviews/test/tooltip-rules.ts). Icon-only controls,
    /// shortcuts and regions keep theirs.
    var repeatsVisibleLabel: Bool {
        guard region == nil, shortcut == nil, let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), let view else { return false }
        let label: String? = switch view {
        case let button as NSButton where button.imagePosition != .imageOnly: button.title
        case let field as any ShownText: field.stringValue
        default: nil
        }
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return false }
        return label.caseInsensitiveCompare(text) == .orderedSame
    }

    /// Adds the tracking area while there is text, removes it without.
    private func track(_ on: Bool) {
        guard let view else { return }
        // In a layout screen the screen's one area serves it: no area that AppKit moves with the pane in every frame.
        if on, area == nil, view.isServedByPanePointerArea {
            isServed = true
            return
        }
        if !on, isServed {
            isServed = false
            TooltipPresenter.shared.exit(self)
            return
        }
        if on, area == nil {
            isServed = false
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, WindowPlacement.noActivate ? .activeAlways : .activeInActiveApp]
            if region == nil { options.insert(.inVisibleRect) }
            let made = NSTrackingArea(rect: region ?? .zero, options: options, owner: self, userInfo: nil)
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

/// A view's tooltips: its own and its regions'.
@MainActor
final class TrackerSet {
    var whole: TooltipTracker?
    var regions: [TooltipTracker] = []
    /// ``NSView/defersThemedToolTipTracking``.
    var defers = false
}
