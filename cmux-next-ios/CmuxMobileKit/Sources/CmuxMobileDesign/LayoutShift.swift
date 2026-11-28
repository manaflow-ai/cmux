// LayoutShiftCounter (the pure frame-to-frame rule) lives in CmuxMobileDesignCore, which builds and tests
// on Linux; re-exported so `import CmuxMobileDesign` keeps it.
@_exported import CmuxMobileDesignCore

#if os(iOS)
import QuartzCore
import SwiftUI
import UIKit

/// With `-cmux-placeholder-markers` (the ios-placeholder-bounds suite's launch argument), counts
/// layout shifts of every `.layoutShiftTracked` row once per display frame and shows the counts as
/// one JSON object in the label `debug.layout-shift` (`LayoutShiftProbeLabel`, at the app's root).
/// Nothing runs without that argument.
@MainActor
@Observable
public final class LayoutShiftProbe {
    public static let shared: LayoutShiftProbe? = PlaceholderBound.markersEnabled ? LayoutShiftProbe() : nil

    public private(set) var text = "{}"

    @ObservationIgnored private var rows: [String: LayoutShiftCounter.Row] = [:]
    /// Which tracked view reports each id: a card is also drawn as the live page's stand-in, the
    /// zoom's copy and a context-menu preview, and two views writing one id read as one row
    /// jumping between them every frame.
    @ObservationIgnored private var owners: [String: UUID] = [:]
    /// UIKit lists that report their own rows (`watch`).
    @ObservationIgnored private var lists: [WatchedList] = []

    private struct WatchedList {
        weak var view: UIScrollView?
        let prefix: String
        let rows: () -> [(id: String, frame: CGRect, content: Int?)]
    }
    /// Each watched list's content offset at the last frame counted, so its rows carry the scroll
    /// it made since (`LayoutShiftCounter.Row.scrolled`).
    @ObservationIgnored private var offsets: [ObjectIdentifier: CGPoint] = [:]
    @ObservationIgnored private var counter = LayoutShiftCounter()
    @ObservationIgnored private var link: CADisplayLink?

    private init() {
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func set(_ id: String, _ row: LayoutShiftCounter.Row?, by token: UUID) {
        if let row {
            guard owners[id] == nil || owners[id] == token else { return }
            owners[id] = token
            rows[id] = row
        } else if owners[id] == token {
            owners[id] = nil
            rows[id] = nil
        }
    }

    /// A UIKit list (the chat transcript) whose rows are counted: `rows` gives each row inside the
    /// list's visible bounds and its frame there (content frame less the content offset), as
    /// `LoadFrameProbe.watch` does. Nothing is counted while the list is off screen or hidden.
    /// Measured in the list, so a transform of the list (the grid's zoom, the live page following
    /// its card) is not a shift, and native and SwiftUI cells are counted alike. `content` is each
    /// row's content revision, so a row growing with new content is not a shift
    /// (`LayoutShiftCounter.Row.content`).
    public func watch(_ view: UIScrollView, prefix: String, rows: @escaping () -> [(id: String, frame: CGRect, content: Int?)]) {
        lists.append(WatchedList(view: view, prefix: prefix, rows: rows))
    }

    /// `advance`: the frame being counted, so each list's offset is taken as the last one
    /// (the JSON's row count reads the rows again without it).
    private func listRows(advance: Bool = false) -> [String: LayoutShiftCounter.Row] {
        lists.removeAll { $0.view == nil }
        var out: [String: LayoutShiftCounter.Row] = [:]
        var seen: [ObjectIdentifier: CGPoint] = [:]
        for list in lists {
            guard let view = list.view, Self.isShown(view) else { continue }
            let key = ObjectIdentifier(view), offset = view.contentOffset
            seen[key] = offset
            // Scrolling by +d moves the rows by -d in the list's visible bounds.
            let scrolled = offsets[key].map { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
            let visible = CGRect(origin: .zero, size: view.bounds.size)
            for (id, frame, content) in list.rows() where frame.intersects(visible) {
                out[list.prefix + id] = .init(frame, .window, content: content, scrolled: scrolled)
            }
        }
        if advance { offsets = seen }
        return out
    }

    /// In a window and not hidden or transparent (a tab kept alive under another).
    private static func isShown(_ view: UIView) -> Bool {
        guard view.window != nil else { return false }
        var next: UIView? = view
        while let v = next {
            if v.isHidden || v.alpha < 0.01 || v.layer.opacity < 0.01 { return false }
            next = v.superview
        }
        return true
    }

    fileprivate func tick() {
        let frames = counter.frames, shifts = counter.shiftFrames
        counter.frame(lists.isEmpty ? rows : rows.merging(listRows(advance: true)) { first, _ in first })
        guard counter.frames != frames, counter.frames == 1 || counter.shiftFrames != shifts || counter.frames % 30 == 0 else { return }
        let json: [String: Any] = [
            "frames": counter.frames, "shiftFrames": counter.shiftFrames,
            "shiftedRows": counter.shiftedRows, "lastMoved": counter.lastMoved, "moves": counter.moves, "rows": rows.count + listRows().count,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        text = String(data: data, encoding: .utf8) ?? "{}"
    }

    private final class Ticker: NSObject {
        weak var probe: LayoutShiftProbe?
        init(_ probe: LayoutShiftProbe) { self.probe = probe }
        /// Reads the weak reference here, so the main-actor closure captures the (Sendable,
        /// main-actor) probe and not this non-Sendable target.
        @objc func tick() {
            let probe = probe
            MainActor.assumeIsolated { probe?.tick() }
        }
    }
}

/// The probe's label, mounted once at the app's root.
public struct LayoutShiftProbeLabel: View {
    public init() {}

    public var body: some View {
        if let probe = LayoutShiftProbe.shared {
            Text(probe.text)
                .lineLimit(1)
                .frame(width: 4, height: 4)
                .clipped()
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.layout-shift")
                .accessibilityLabel(probe.text)
        }
    }
}

/// The coordinate space `.layoutShiftHost()` names: the root of a UIKit-hosted SwiftUI view that
/// sits outside any scroll view (the chat's composer dock).
let layoutShiftHostSpace = "cmux.layoutShift.host"

private struct LayoutShiftTracked: ViewModifier {
    let id: String
    let space: LayoutShiftCounter.Space
    /// Measured in its `.layoutShiftHost()` instead of a scroll view.
    var inHost = false
    @State private var token = UUID()

    func body(content: Content) -> some View {
        if let probe = LayoutShiftProbe.shared {
            let space = space, token = token, inHost = inHost
            content
                .onGeometryChange(for: CGRect?.self) { proxy in
                    inHost ? Self.measureInHost(proxy) : Self.measure(proxy, space)
                } action: { rect in
                    probe.set(id, rect.map { .init($0, inHost ? .scrollContent : space) }, by: token)
                }
                .onDisappear { probe.set(id, nil, by: token) }
        } else {
            content
        }
    }

    /// The row's frame in its scroll view, while some of it is inside the scroll view's visible
    /// bounds; nil off them, or outside any scroll view (a copy of a card: the zoom's, a preview).
    /// Never the screen: a transform of the whole list (the grid's zoom scale) is not a shift.
    private nonisolated static func measure(_ proxy: GeometryProxy, _ space: LayoutShiftCounter.Space) -> CGRect? {
        guard let visible = proxy.bounds(of: .scrollView),
              visible.intersects(CGRect(origin: .zero, size: proxy.size)) else { return nil }
        let frame = proxy.frame(in: .scrollView)
        guard space == .window else { return frame }
        // `.window`: the frame in the scroll view's visible bounds (a scroll moves every row alike),
        // in the scroll view's points. `visible` is in the row's own space, which a scale between
        // them (the tab grid's cards are pages drawn at ~0.44) makes larger: taken as is, the
        // origin was in page points and the size in grid points, so a scroll's sub-point rounding,
        // magnified 2.3x, split the cards' moves past the tolerance (tab-grid-51, one frame).
        let scale = proxy.size.width > 0 ? frame.width / proxy.size.width : 1
        return CGRect(origin: CGPoint(x: -visible.minX * scale, y: -visible.minY * scale), size: frame.size)
    }

    /// The view's frame in its host's root (`.layoutShiftHost()`), its y taken from the host's
    /// bottom edge (a dock grows upward: a notice shown over the composer moves nothing under it);
    /// nil without a host above it (never the screen) or while it has no size. The host itself
    /// moving (a push, the keyboard raising the dock) moves nothing in it, so only the view moving
    /// or resizing in its host counts.
    private nonisolated static func measureInHost(_ proxy: GeometryProxy) -> CGRect? {
        guard let host = proxy.bounds(of: .named(layoutShiftHostSpace)) else { return nil }
        let frame = proxy.frame(in: .named(layoutShiftHostSpace))
        guard frame.width > 0, frame.height > 0 else { return nil }
        return CGRect(x: frame.minX, y: frame.minY - host.height, width: frame.width, height: frame.height)
    }
}

public extension View {
    /// Marks a row or card whose frame the layout-shift count watches (`LayoutShiftCounter`);
    /// nothing without `-cmux-placeholder-markers`. `id` is unique on screen.
    func layoutShiftTracked(_ id: String, in space: LayoutShiftCounter.Space = .scrollContent) -> some View {
        modifier(LayoutShiftTracked(id: id, space: space))
    }

    /// Marks a view outside any scroll view (the chat's composer) whose frame in its
    /// `.layoutShiftHost()` the layout-shift count watches: any move or resize there counts.
    func layoutShiftTracked(inHost id: String) -> some View {
        modifier(LayoutShiftTracked(id: id, space: .scrollContent, inHost: true))
    }

    /// The root of a UIKit-hosted SwiftUI view whose `.layoutShiftTracked(inHost:)` views are
    /// measured in it (the chat's dock, pinned to the keyboard).
    func layoutShiftHost() -> some View {
        coordinateSpace(.named(layoutShiftHostSpace))
    }
}
#endif
