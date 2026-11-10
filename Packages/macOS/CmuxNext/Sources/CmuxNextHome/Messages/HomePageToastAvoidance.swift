public import AppKit
import CmuxNextDesign
public import CmuxNextPages
public import CmuxNextSettings

/// A toast never covers a Messages page's compose bar, and the bar never moves for a toast (Leo,
/// 2026-11-07: "The composer should never ever rise up because there's some sort of ... tooltip type
/// thing"). Toasts rest bottom-center over the window, over the page's foot where the bar is. The page
/// reports the bar's box (`cmux.home.messages.toastAvoidance {rects}`, viewport CSS pixels; webviews
/// home-messages detailHost.ts `homeToastAvoidance` over agent-session/acpmux/toastAvoidance.ts) and
/// the view that holds the page is a ``CmuxToastAvoiding`` whose rect is this box, so the toast host
/// lifts every toast above it. The agent pane's `AgentPaneView+ToastAvoidance.swift`, ported: the same
/// conversion with the page zoom, and the window's toasts told when the box or the view moves, hides
/// or changes window. The page's layout never hears of a toast.
@MainActor
public final class HomePageToastAvoidance {
    /// The op this answers, after `cmux.home.messages.`.
    public nonisolated static let op = "toastAvoidance"
    /// The bar's box the page last reported (viewport CSS pixels, top-left origin); nil: none.
    public private(set) var box: CGRect?
    private weak var view: NSView?
    private weak var page: PageWebView?
    /// What the window was last told (window coordinates), and which window.
    private var last: NSRect = .zero
    private weak var lastWindow: NSWindow?

    public init() {}

    /// `view` (whose subview `page` is) avoids the box: its rect is ``rect(in:)``. A watcher subview
    /// tells the window's toasts when `view` hides, shows again (itself or an ancestor: a workspace
    /// switch changes no frame) or changes window; `view`'s own layout calls ``moved()``.
    public func attach(_ view: NSView, page: PageWebView) {
        self.view = view
        self.page = page
        let watcher = Watcher(frame: view.bounds)
        watcher.autoresizingMask = [.width, .height]
        watcher.changed = { [weak self] in self?.moved() }
        view.addSubview(watcher, positioned: .below, relativeTo: nil)
    }

    /// A page call: `toastAvoidance {rects}` keeps the box (one, or none) and moves the window's
    /// toasts; nil for any other op.
    public func call(_ name: String, _ fields: [String: JSONValue]) throws -> JSONValue? {
        guard name == Self.op else { return nil }
        guard let rects = fields["rects"]?.arrayValue, rects.count <= 1 else { throw PageError.invalidParams("rects must hold at most one box") }
        let box: CGRect?
        if let first = rects.first {
            guard let decoded = Self.decode(first) else { throw PageError.invalidParams("a box is {left, top, right, bottom}") }
            box = decoded
        } else { box = nil }
        report(box)
        return .null
    }

    /// The page reported `box` (nil: none).
    public func report(_ box: CGRect?) {
        guard box != self.box else { return }
        self.box = box
        moved()
    }

    /// The box in `target`'s coordinates; empty while the page reports none or no view holds it.
    public func rect(in target: NSView) -> NSRect {
        guard let box, let page, page.window === target.window else { return .zero }
        let local = Self.viewRect(box, page: page.bounds, zoom: CGFloat(page.pageZoom), flipped: page.isFlipped)
        return target.convert(local, from: page)
    }

    /// The box or the view moved, or the view was hidden, shown or moved to another window: that
    /// window's shown toasts move clear of where the bar is now. A hidden view avoids nothing. A
    /// move to another window counts even at the same frame: the toasts there move above the bar,
    /// and those of the window it left come back down. Says nothing when the window and the rect
    /// there are unchanged, so a layout pass with no move costs no toast work.
    public func moved() {
        guard let view else { return }
        let window = view.window
        let rect = window == nil || view.isHiddenOrHasHiddenAncestor ? NSRect.zero : view.convert(rect(in: view), to: nil)
        let left = lastWindow
        guard rect != last || left !== window else { return }
        last = rect
        lastWindow = window
        if let left, left !== window { CmuxToastAvoidance.avoidanceChanged(in: left) }
        if let window { CmuxToastAvoidance.avoidanceChanged(in: window) }
    }

    /// A page's box (viewport CSS pixels, top-left origin) in a page frame `page` (points): scaled by
    /// the page zoom, and from the bottom in an unflipped view (`AgentPaneView.sessionInfoOverlayRect`).
    nonisolated static func viewRect(_ rect: CGRect, page: CGRect, zoom: CGFloat, flipped: Bool) -> CGRect {
        let scale = max(0.25, zoom)
        let x = page.minX + rect.minX * scale
        let y = flipped ? page.minY + rect.minY * scale : page.maxY - rect.maxY * scale
        return CGRect(x: x, y: y, width: rect.width * scale, height: rect.height * scale)
    }

    /// `{left, top, right, bottom}`, each finite and within ±100000, not inverted; nil otherwise
    /// (`AgentPaneSessionInfoOverlay.decode`'s rule).
    nonisolated static func decode(_ value: JSONValue) -> CGRect? {
        guard let box = value.objectValue else { return nil }
        let number = { (key: String) -> Double? in
            guard let value = box[key]?.doubleValue, value.isFinite, abs(value) <= 100_000 else { return nil }
            return value
        }
        guard let left = number("left"), let top = number("top"), let right = number("right"), let bottom = number("bottom"),
              right >= left, bottom >= top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Hears what the view it lies in hears of hiding and windows (AppKit tells every subview when an
    /// ancestor hides or shows). It draws nothing and takes no click.
    final class Watcher: NSView {
        var changed: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidHide() {
            super.viewDidHide()
            changed?()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            changed?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            changed?()
        }
    }
}
