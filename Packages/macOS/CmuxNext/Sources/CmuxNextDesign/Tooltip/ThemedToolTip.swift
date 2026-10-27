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

    /// The tooltip the content under the pointer asks for (a web page's `title=`), shown below the
    /// pointer: Chrome's page view takes it as `SetTooltipText` and shows it with
    /// `-setToolTipAtMousePoint:` (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm).
    /// It comes while the pointer is already over the view, where a new tracking area reports no
    /// enter, so it enters at once, as Chrome's view sends AppKit's tooltip owner a fake enter. The
    /// same text again changes nothing. Nil or empty: none.
    public func setThemedToolTipAtPointer(_ text: String?) {
        TooltipTracker.setAtPointer(text, on: self)
    }

    /// Tooltips for parts of the view (AppKit's `addToolTip(_:owner:userData:)`), in its coordinates;
    /// replaces the previous ones. A region wins over the view's own tooltip.
    public func setThemedToolTipRegions(_ regions: [(rect: NSRect, text: String)]) {
        TooltipTracker.setRegions(regions, on: self)
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
    /// It hangs below the pointer, not the view (``NSView/setThemedToolTipAtPointer(_:)``).
    private(set) var atPointer = false
    private var area: NSTrackingArea?

    static func whole(of view: NSView) -> TooltipTracker? { trackers.object(forKey: view)?.whole }

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
        tracker.track(text != nil)
        TooltipPresenter.shared.changed(tracker)
    }

    /// ``NSView/setThemedToolTipAtPointer(_:)``: the view's tooltip, entered at once when the pointer
    /// is over the view; `presenter` is the app's one but in tests.
    static func setAtPointer(_ text: String?, on view: NSView, presenter: TooltipPresenter = .shared) {
        let text = text?.isEmpty == false ? text : nil
        guard text != whole(of: view)?.text else { return }
        setWhole(text, shortcut: nil, on: view)
        guard let tracker = whole(of: view) else { return }
        tracker.atPointer = true
        if text != nil, tracker.isUnderPointer { presenter.enter(tracker) }
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

    /// The pointer is over the visible view or region now.
    var isUnderPointer: Bool {
        guard let window = view?.window, let anchor = screenRect, let pointer = PointerHover.pointer(in: window) else { return false }
        return anchor.contains(window.convertPoint(toScreen: pointer))
    }

    /// How far a tooltip at the pointer hangs below the pointer's hot spot: the arrow cursor's height
    /// below it, so the tooltip clears the cursor as AppKit's does.
    static let pointerDrop: CGFloat = 20

    /// What the tooltip hangs below, in screen coordinates: the visible view or region, or for one at
    /// the pointer a box from the pointer down by ``pointerDrop``; nil when the view is not shown.
    var anchorScreenRect: NSRect? {
        guard atPointer else { return screenRect }
        guard let window = view?.window, screenRect != nil, let pointer = PointerHover.pointer(in: window) else { return nil }
        let point = window.convertPoint(toScreen: pointer)
        return NSRect(x: point.x, y: point.y - Self.pointerDrop, width: 1, height: Self.pointerDrop)
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
        if on, area == nil {
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
}
