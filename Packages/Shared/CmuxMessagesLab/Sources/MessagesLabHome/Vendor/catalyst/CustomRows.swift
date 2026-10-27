#if canImport(UIKit)
import UIKit
/// The view type a provider hosts in a custom row (UIKit hosts).
typealias CustomRowPlatformView = UIView
#else
import AppKit
/// The view type a provider hosts in a custom row (AppKit hosts: NSView, SwiftUI inside
/// through NSHostingView).
typealias CustomRowPlatformView = NSView
#endif
import os // cmux: OSAllocatedUnfairLock

// Hosted rows: interactive rows that a host app puts into the transcript without
// patching the shared files (appkit-native/CUSTOM-ROWS.md). The model is a part
// (`Part.custom`), so the store, write-through and pager persist and page it like any
// other part. The transcript draws the row's chrome (bubble, tail, tapbacks) in the
// row bitmap and the host shows the provider's live view over it (appkit-native:
// CustomRowsHost.swift). Without a live host (Catalyst, iOS, captures) the row is a
// text bubble with the provider's plain text.

/// A host-defined part: `kind` selects the provider, `payload` is the host's own bytes
/// (usually JSON of a Codable), `version` changes whenever the payload changes (the
/// measure cache and the row bitmaps key on it).
struct CustomPart: Codable, Hashable {
    var kind: String
    var version: Int
    var payload: Data

    init(kind: String, version: Int, payload: Data) {
        self.kind = kind
        self.version = version
        self.payload = payload
    }
    /// JSON of `value` as the payload.
    init<T: Encodable>(kind: String, version: Int, value: T) throws {
        self.init(kind: kind, version: version, payload: try JSONEncoder().encode(value))
    }
    /// The payload decoded as JSON of `T` (nil: other bytes).
    func decode<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: payload) }
    /// A copy with a new payload and the next version.
    func updated<T: Encodable>(_ value: T) -> CustomPart {
        (try? CustomPart(kind: kind, version: version + 1, value: value)) ?? self
    }
}

/// Where a custom row sits. `sender`: a bubble on the sender's side (as every other part).
enum CustomRowLayout: Hashable {
    case sender, bubbleIncoming, bubbleOutgoing, fullWidth
}

/// Keys a focused row sees first (others fall through to the compose field).
enum CustomRowKey: Hashable {
    case digit(Int)          // 1...9
    case up, down, left, right
    case enter, escape
    case tab(backward: Bool)
}

/// Calls a hosted view makes back into the transcript (main thread).
protocol CustomRowActions: AnyObject {
    /// Store a new payload (bump `version`): the part is written through, re-measured, and a
    /// height change animates (rows below move; the viewport anchor stays).
    func update(_ part: CustomPart)
    /// Same payload, new height (view-local state): re-measure and animate.
    func heightDidChange()
    /// Give the row the key focus / give it back to the compose field.
    func focus()
    func resignFocus()
}

/// What `configure` gets besides the part.
struct CustomRowContext {
    var ref: PartRef
    /// The view's size (the measured content size; full width rows: the column).
    var size: CGSize
    /// Resolved layout (never `.sender`).
    var layout: CustomRowLayout
    /// The row has the key focus (the view or a subview is the first responder).
    var isFocused: Bool
    /// The window is key (inactive windows draw their bubbles flat).
    var isWindowKey: Bool
    /// The transcript draws dark (Fixture.lightAppearance false).
    var isDark: Bool
    var actions: CustomRowActions?
}

/// A host's provider for one `kind`.
///
/// Threading: `measure` must be pure and deterministic for (payload version, maxWidth).
/// With `measuresOffMain` true it runs on any thread (page loads measure on the loader
/// queue). With false it runs on the main thread only: rows loaded off main get
/// `estimate` and are measured on main when they come near the viewport (the same
/// estimate -> measure correction as long text: a correction keeps the first visible
/// row in place, so it moves only content outside the viewport).
/// cmux: Sendable (p10-stability-040): the registry hands a provider to the loader queue and
/// the row bitmap threads, so a provider keeps no unsynchronized state; its view calls are
/// main-actor.
protocol TranscriptCustomRowProvider: AnyObject, Sendable {
    var kind: String { get }
    var measuresOffMain: Bool { get }
    func layout(for part: CustomPart) -> CustomRowLayout
    /// Content size for at most `maxWidth` (bubble modes: the bubble; full width: only the
    /// height is used).
    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize
    /// Cheap guess for a main-only provider's off-main rows.
    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize
    /// A new view (the host keeps a pool per kind and reuses it for any row of the kind).
    @MainActor func makeView() -> CustomRowPlatformView
    /// Show `part` (called on reuse and on every change of part, size, focus, key state).
    @MainActor func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext)
    /// The view leaves its row (back to the pool).
    @MainActor func prepareForReuse(_ view: CustomRowPlatformView)
    /// A key while the row has the focus. true: handled.
    @MainActor func handleKey(_ key: CustomRowKey, view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) -> Bool
    /// Copy, VoiceOver and preview text (nil: "[kind]").
    func plainText(_ part: CustomPart) -> String?
    /// The provider draws the row into its row bitmap (`drawRow`), with no live view: a host
    /// without a live-view host (cmux Home: an agent run card). Rows measure with the provider
    /// then even where live views are off. Default false.
    var drawsRow: Bool { get }
    /// Draw `part` in `rect` (the body: the bubble, drawn first in the bubble modes, or the
    /// column for full width rows). Any thread (row bitmaps draw off main); pure.
    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext)
    /// A click on the row (`MessagesWindowView.hostControl`; main thread). true: taken (the host
    /// does nothing more with the click, e.g. it opens a sheet). Default false.
    func tapped(_ part: CustomPart, ref: PartRef) -> Bool
}

/// What `drawRow` gets besides the part.
struct CustomRowDrawContext {
    var outgoing: Bool
    /// The transcript draws dark (Fixture.lightAppearance false).
    var isDark: Bool
    /// A thread view copy (the elevated palette).
    var elevated: Bool
}

extension TranscriptCustomRowProvider {
    var measuresOffMain: Bool { false }
    func layout(for part: CustomPart) -> CustomRowLayout { .sender }
    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { CGSize(width: maxWidth, height: 120) }
    func prepareForReuse(_ view: CustomRowPlatformView) {}
    func handleKey(_ key: CustomRowKey, view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) -> Bool { false }
    func plainText(_ part: CustomPart) -> String? { nil }
    var drawsRow: Bool { false }
    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {}
    func tapped(_ part: CustomPart, ref: PartRef) -> Bool { false }
}

/// A drawn custom row from closures (ask 7: cmux's agent run card). The host gives the kind, the
/// height for a width, the drawing and the tap; register it with `CustomRows.register`. The
/// closures `height`, `draw` and `text` run on any thread (measure on the loader queue, row
/// bitmaps on their threads): keep them pure over the part's payload. `tap` runs on main.
final class DrawnRowProvider: TranscriptCustomRowProvider {
    let kind: String
    let rowLayout: CustomRowLayout
    // cmux: @Sendable closures (they run on any thread, and the provider is Sendable).
    private let height: @Sendable (CustomPart, CGFloat) -> CGFloat
    private let draw: @Sendable (CustomPart, CGContext, CGRect, CustomRowDrawContext) -> Void
    private let text: @Sendable (CustomPart) -> String?
    private let tap: (@Sendable (CustomPart, PartRef) -> Bool)?

    init(kind: String, layout: CustomRowLayout = .fullWidth,
         height: @escaping @Sendable (CustomPart, CGFloat) -> CGFloat,
         draw: @escaping @Sendable (CustomPart, CGContext, CGRect, CustomRowDrawContext) -> Void,
         text: @escaping @Sendable (CustomPart) -> String? = { _ in nil },
         tap: (@Sendable (CustomPart, PartRef) -> Bool)? = nil) {
        self.kind = kind
        self.rowLayout = layout
        self.height = height
        self.draw = draw
        self.text = text
        self.tap = tap
    }

    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { rowLayout }
    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { CGSize(width: maxWidth, height: max(1, height(part, maxWidth))) }
    @MainActor func makeView() -> CustomRowPlatformView { CustomRowPlatformView() } // cmux: main-actor, as the requirement
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) { draw(part, ctx, rect, context) }
    func plainText(_ part: CustomPart) -> String? { text(part) }
    func tapped(_ part: CustomPart, ref: PartRef) -> Bool { tap?(part, ref) ?? false }
}

/// The live-view side, implemented by a host (appkit-native CustomRowsHost). The shared
/// transcript calls it from the row cell, the recycler and the window view's decorate.
/// cmux: Sendable, as the registry's other entries (`CustomRows.host` is read from any thread).
protocol CustomRowHosting: AnyObject, Sendable {
    /// A cell shows `spec` (end of RowCell.configure / showNow).
    func configure(_ cell: RowCell, _ spec: RowSpec)
    /// A cell goes back to the pool.
    func detach(_ cell: RowCell)
    /// After a recycler layout pass (scroll, commit, paging).
    func didLayout(_ list: RowRecycler)
    /// After the window view applied a row's animations to `cell`.
    func decorated(_ cell: RowCell)
}

enum CustomRows {
    /// The live host (nil: no live views; rows are text bubbles).
    static var host: CustomRowHosting? { // cmux: in `lock`
        get { lock.withLock { $0.host } }
        set { lock.withLock { $0.host = newValue } }
    }
    /// Live views are shown in this app: custom rows measure with their provider
    /// (appkit-native: on; Catalyst, iOS: off, the stub). cmux: a constant (nothing sets it,
    /// and an unsynchronized global was read off main).
    #if APPKIT_NATIVE
    static let liveViews = true
    #else
    static let liveViews = false
    #endif

    /// cmux: the providers, the host and the estimate flag inside the lock (an NSLock beside
    /// globals the checker could not see). Lock carve-out: rows measure and draw synchronously
    /// on the loader queue and the row bitmap threads.
    private struct Registry: Sendable {
        var providers: [String: any TranscriptCustomRowProvider] = [:]
        var host: (any CustomRowHosting)?
        var mayEstimate = false
    }
    private static let lock = OSAllocatedUnfairLock(initialState: Registry())

    static func register(_ p: TranscriptCustomRowProvider) { let kind = p.kind; lock.withLock { $0.providers[kind] = p }; cache.clear() }
    static func unregister(_ kind: String) { lock.withLock { $0.providers[kind] = nil }; cache.clear() }
    static func provider(_ kind: String) -> TranscriptCustomRowProvider? { lock.withLock { $0.providers[kind] } }

    /// The provider when its live view is shown here, or when it draws the row itself (`drawsRow`).
    static func live(_ c: CustomPart) -> TranscriptCustomRowProvider? {
        guard let p = provider(c.kind) else { return nil }
        return liveViews || p.drawsRow ? p : nil
    }
    /// The provider when a live-view host shows its view (a drawn row has none).
    static func hosted(_ c: CustomPart) -> TranscriptCustomRowProvider? {
        guard liveViews, let p = provider(c.kind), !p.drawsRow else { return nil }
        return p
    }

    static func plainText(_ c: CustomPart) -> String { provider(c.kind)?.plainText(c) ?? "[\(c.kind)]" }

    /// The layout, `.sender` resolved by `outgoing`.
    static func layout(_ c: CustomPart, outgoing: Bool) -> CustomRowLayout {
        guard let p = live(c) else { return outgoing ? .bubbleOutgoing : .bubbleIncoming }
        let l = p.layout(for: c)
        return l == .sender ? (outgoing ? .bubbleOutgoing : .bubbleIncoming) : l
    }
    /// The row's side: a provider may put a row on either side whoever sent it.
    static func outgoing(_ part: Part, sender: Bool) -> Bool {
        guard case let .custom(c) = part, let p = live(c) else { return sender }
        switch p.layout(for: c) {
        case .bubbleIncoming, .fullWidth: return false
        case .bubbleOutgoing: return true
        case .sender: return sender
        }
    }
    /// Outgoing bubbles take the window gradient layer (RowDraw.needsFill).
    static func needsFill(_ c: CustomPart, outgoing: Bool) -> Bool { outgoing && layout(c, outgoing: outgoing) != .fullWidth }

    static func maxWidth(_ c: CustomPart, width: CGFloat) -> CGFloat {
        let m = Metrics(width: width)
        if let p = live(c), p.layout(for: c) == .fullWidth { return m.rightEdge - Fixture.leftEdge }
        return m.maxTextWidth + 2 * Fixture.bubblePadX
    }

    // MARK: Measure

    /// (size, text layout of the fallback bubble, estimated). Thread safe.
    /// `id` nil: not cached (a part outside a message).
    static func measure(_ c: CustomPart, message id: ID?, part pi: Int, width: CGFloat) -> (CGSize, TextLayout?, Bool) {
        guard let p = live(c) else {
            // The stub: a text bubble with the plain text (no live view here).
            let (s, tl) = Sizing.size(of: .text(plainText(c), runs: []), width: width)
            return (s, tl, false)
        }
        let maxW = maxWidth(c, width: width)
        let full = p.layout(for: c) == .fullWidth
        func fit(_ s: CGSize) -> CGSize { CGSize(width: full ? maxW : min(maxW, max(1, s.width.rounded())), height: max(1, s.height.rounded())) }
        let k = id.map { MeasureKey(id: $0, part: pi, version: c.version, width: width, generation: cache.generation($0)) }
        if let k, let s = cache.get(k) { return (s, nil, false) }
        if !p.measuresOffMain && !Thread.isMainThread { mayEstimate = true; return (fit(p.estimate(c, maxWidth: maxW)), nil, true) }
        let s = fit(p.measure(c, maxWidth: maxW))
        if let k { cache.put(k, s) }
        return (s, nil, false)
    }
    /// Some row got an estimate (a main-only provider measured off main): hosts look for rows
    /// to correct near the viewport. Never set for histories without custom rows.
    static var mayEstimate: Bool { // cmux: in `lock`
        get { lock.withLock { $0.mayEstimate } }
        set { lock.withLock { $0.mayEstimate = newValue } }
    }
    /// The next measure of `id`'s custom parts runs again (heightDidChange).
    static func invalidate(_ id: ID) { cache.bump(id) }

    struct MeasureKey: Hashable { var id: ID; var part: Int; var version: Int; var width: CGFloat; var generation: Int }
    static let cache = MeasureStore()
    /// cmux: its state behind a checked lock (it was `@unchecked Sendable` over an NSLock).
    final class MeasureStore: Sendable {
        private struct State: Sendable {
            var sizes: [MeasureKey: CGSize] = [:]
            var generations: [ID: Int] = [:]
        }
        // Lock carve-out: measured synchronously on the loader queue and the main thread.
        private let state = OSAllocatedUnfairLock(initialState: State())
        func get(_ k: MeasureKey) -> CGSize? { state.withLock { $0.sizes[k] } }
        func put(_ k: MeasureKey, _ s: CGSize) {
            state.withLock { st in
                if st.sizes.count > 20_000 { st.sizes.removeAll(keepingCapacity: true) }
                st.sizes[k] = s
            }
        }
        func generation(_ id: ID) -> Int { state.withLock { $0.generations[id] ?? 0 } }
        func bump(_ id: ID) { state.withLock { $0.generations[id, default: 0] += 1 } }
        func clear() { state.withLock { $0.sizes.removeAll() } }
        var count: Int { state.withLock { $0.sizes.count } }
    }

    // MARK: Drawing (row bitmap)

    /// The row bitmap of a custom part: the bubble (bubble modes) or nothing (full width);
    /// the stub draws the fallback text bubble.
    static func draw(_ ctx: CGContext, _ c: CustomPart, row p: PartRow, body: CGRect, windowY: CGFloat) {
        guard live(c) != nil else {
            BubbleView.drawBubble(ctx, body: body, lines: [], outgoing: p.outgoing, tail: p.tail, windowY: windowY)
            if let tl = p.text { PartRenderer.drawText(ctx, tl, in: body, outgoing: p.outgoing) }
            return
        }
        guard let prov = live(c) else { return }
        let full = layout(c, outgoing: p.outgoing) == .fullWidth
        if !full { BubbleView.drawBubble(ctx, body: body, lines: [], outgoing: p.outgoing, tail: p.tail, windowY: windowY) }
        guard prov.drawsRow else { return }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let elevated = false    // the iOS app's Fixture has no thread copy palette
        #else
        let elevated = Fixture.elevated
        #endif
        ctx.saveGState()
        prov.drawRow(c, in: ctx, rect: body, context: CustomRowDrawContext(outgoing: p.outgoing, isDark: !Fixture.lightAppearance, elevated: elevated))
        ctx.restoreGState()
    }

    /// The hosted view's rect in row (cell) coordinates.
    static func viewRect(_ spec: RowSpec) -> CGRect { RowDraw.bodyRect(spec) }

    // MARK: Estimate corrections
    #if !os(iOS) || targetEnvironment(macCatalyst)

    /// Custom rows with estimated heights within `margin` of the viewport (content y):
    /// their message ids. Main thread.
    static func estimatedNear(_ v: MessagesWindowView, margin: CGFloat) -> [ID] {
        guard v.model.count > 0 else { return [] }
        let y = v.collection.contentOffset.y - v.layout.rowsTop
        var ids: [ID] = []
        for i in v.model.range(y - margin, y + v.cvHeight + margin) {
            guard let s = v.model.rows[checked: i]?.spec else { continue } // checked
            guard s.estimated, case let .part(p) = s.kind, case .custom = p.part else { continue }
            if ids.last != p.ref.messageId { ids.append(p.ref.messageId) }
        }
        return ids
    }
    #endif
}
