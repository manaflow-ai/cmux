public import AppKit

/// Every scroller in cmux is thin and never a gray track, whatever the macOS
/// "Show scroll bars" setting (SCROLLBARS-THIN, Leo 2026-10-12: "never a
/// permanent gray track"). Native scroll views call `follow(_:)` once and get
/// ``nativeStyle`` (overlay), also after the setting changes; `followThin(_:)`
/// adds the shared ``ThinScroller``. A scroll view with rows and columns (a
/// sideways bar) gets the thin scroller on both axes from `follow(_:)` too: no
/// track on either bar and no fill where they meet (Lawrence 2026-10-23, msg
/// 12114: "do not have extra bg").
/// Pages read `pageValue`, the setting itself: WebKit draws legacy bars for
/// "Always", which the shared web rules (webviews/src/scrollers.ts) thin.
/// The setting is tracked live through
/// `NSScroller.preferredScrollerStyleDidChangeNotification` (one observer,
/// no polling).
@MainActor
public struct SystemScrollers {
    public init() {}
    /// Tests set the system's answer; nil reads `NSScroller.preferredScrollerStyle`.
    public static var preferredStyleOverride: NSScroller.Style?

    public static var preferredStyle: NSScroller.Style { preferredStyleOverride ?? NSScroller.preferredScrollerStyle }

    /// The style of every native scroller: overlay, hidden at rest and shown while scrolling.
    public static let nativeStyle: NSScroller.Style = .overlay

    /// "overlay" or "legacy", for web pages (a root class or theme value).
    public static var pageValue: String { preferredStyle == .legacy ? "legacy" : "overlay" }

    private static var followed: [WeakScrollView] = []
    private static var observers: [Observer] = []
    private static var notifications: Task<Void, Never>?

    /// Gives `scrollView` ``nativeStyle`` now and after every change of the setting (AppKit resets
    /// a scroll view to the system's style then). One that scrolls sideways too gets the shared
    /// ``ThinScroller`` on both bars: AppKit's overlay scrollers paint a track while the pointer is
    /// over them. A table's header corner (the square above the vertical bar) is removed.
    public static func follow(_ scrollView: NSScrollView) {
        if scrollView.hasHorizontalScroller {
            if !(scrollView.horizontalScroller is ThinScroller) { scrollView.horizontalScroller = ThinScroller() }
            if !(scrollView.verticalScroller is ThinScroller) { scrollView.verticalScroller = ThinScroller() }
        }
        // A stock scroller's arrow and page parts have no name (goal a11y-baseline): the scroller
        // that names them draws the same.
        if let scroller = scrollView.verticalScroller, type(of: scroller) == NSScroller.self {
            scrollView.verticalScroller = NamedPartsScroller(replacing: scroller)
        }
        if let scroller = scrollView.horizontalScroller, type(of: scroller) == NSScroller.self {
            scrollView.horizontalScroller = NamedPartsScroller(replacing: scroller)
        }
        (scrollView.documentView as? NSTableView)?.cornerView = nil
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = nativeStyle
        followed.removeAll { $0.value == nil || $0.value === scrollView }
        followed.append(WeakScrollView(scrollView))
        startObserving()
    }

    /// Gives `scrollView` the shared ``ThinScroller`` and follows it like ``follow(_:)``: the
    /// sidebar and every scrollable card (hover cards, the update card's popover) scroll with this
    /// one style, the native twin of the chat's (webviews/src/scrollers.ts).
    public static func followThin(_ scrollView: NSScrollView) {
        if !(scrollView.verticalScroller is ThinScroller) { scrollView.verticalScroller = ThinScroller() }
        follow(scrollView)
    }

    /// The auto-hide of every ``ThinScroller``: true (the default, Lawrence 2026-10-23 msg 11494)
    /// fades its knob out at rest and in while the view scrolls or the pointer nears its edge;
    /// false keeps it shown for as long as the content overflows (Leo 2026-10-21's look).
    public static var thinScrollersAutoHide = true {
        didSet {
            followed.removeAll { $0.value == nil }
            for entry in followed {
                (entry.value?.verticalScroller as? ThinScroller)?.autoHides = thinScrollersAutoHide
                (entry.value?.horizontalScroller as? ThinScroller)?.autoHides = thinScrollersAutoHide
            }
        }
    }

    /// Calls `onChange` with the system's new style on every later change while `owner` lives (the
    /// owner is held weakly). For surfaces that are not a plain NSScrollView: web pages get the
    /// style through their theme payload.
    public static func observe(_ owner: AnyObject, _ onChange: @escaping @MainActor (NSScroller.Style) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, onChange: onChange))
        startObserving()
    }

    private static func startObserving() {
        guard notifications == nil else { return }
        // task-owner: process lifetime (one observer for every scroll view); event-driven.
        notifications = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: NSScroller.preferredScrollerStyleDidChangeNotification) {
                systemStyleDidChange()
            }
        }
    }

    /// Re-applies ``nativeStyle`` to every followed scroll view and tells the observers.
    public static func systemStyleDidChange() {
        followed.removeAll { $0.value == nil }
        let style = preferredStyle
        for entry in followed { entry.value?.scrollerStyle = nativeStyle }
        observers.removeAll { $0.owner == nil }
        for entry in observers { entry.onChange(style) }
    }

    private struct Observer {
        weak var owner: AnyObject?
        let onChange: @MainActor (NSScroller.Style) -> Void
    }

    private struct WeakScrollView {
        weak var value: NSScrollView?
        init(_ value: NSScrollView) { self.value = value }
    }
}


/// AppKit's scroller with names on its arrow and page parts. A stock scroller's parts are buttons
/// with a subrole and nothing else, which an accessibility client that reads names sees as
/// unnamed controls (cmuxterm-hq synthetic-probes run 42599053150: the Home list's four).
final class NamedPartsScroller: NSScroller {
    /// A scroller like `scroller`: its size, knob style and enabled state.
    convenience init(replacing scroller: NSScroller) {
        self.init(frame: scroller.frame)
        controlSize = scroller.controlSize
        knobStyle = scroller.knobStyle
        isEnabled = scroller.isEnabled
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// True while the parts are being named: a part answers its attributes through this scroller's
    /// children, so a read while naming returns them unnamed instead of naming again (which recursed).
    private var namingParts = false

    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren()
        guard !namingParts else { return children }
        namingParts = true
        defer { namingParts = false }
        ScrollerPartNames.name(children, vertical: bounds.height >= bounds.width)
        return children
    }
}

/// The names of a scroller's arrow and page parts, by subrole (``NamedPartsScroller``, ``ThinScroller``).
struct ScrollerPartNames {
    /// Gives each unnamed part of `children` its name; anything else is left as it is.
    @MainActor static func name(_ children: [Any]?, vertical: Bool) {
        for case let part as any NSAccessibilityProtocol in children ?? [] where part.accessibilityRole() == .button {
            guard (part.accessibilityLabel() ?? "").isEmpty, let subrole = part.accessibilitySubrole(),
                  let name = name(for: subrole, vertical: vertical) else { continue }
            part.setAccessibilityLabel(name)
        }
    }

    static func name(for subrole: NSAccessibility.Subrole, vertical: Bool) -> String? {
        switch subrole {
        case .incrementPage:
            vertical ? String(localized: "scroller.part.pageDown", defaultValue: "Page Down", bundle: .module)
                : String(localized: "scroller.part.pageRight", defaultValue: "Page Right", bundle: .module)
        case .decrementPage:
            vertical ? String(localized: "scroller.part.pageUp", defaultValue: "Page Up", bundle: .module)
                : String(localized: "scroller.part.pageLeft", defaultValue: "Page Left", bundle: .module)
        case .incrementArrow:
            vertical ? String(localized: "scroller.part.scrollDown", defaultValue: "Scroll Down", bundle: .module)
                : String(localized: "scroller.part.scrollRight", defaultValue: "Scroll Right", bundle: .module)
        case .decrementArrow:
            vertical ? String(localized: "scroller.part.scrollUp", defaultValue: "Scroll Up", bundle: .module)
                : String(localized: "scroller.part.scrollLeft", defaultValue: "Scroll Left", bundle: .module)
        default: nil
        }
    }
}
