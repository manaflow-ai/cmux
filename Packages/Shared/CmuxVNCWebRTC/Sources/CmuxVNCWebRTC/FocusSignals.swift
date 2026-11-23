import CoreGraphics
import Foundation

// Follow mode's focus signals (host → viewer, the `focus` data channel): where
// the person's attention is on the streamed display, for the viewer's follow
// camera (cmux-tui/crates/cmux-follow-cam). One JSON `Event` per message:
// `{"t_us":…,"kind":"pointer","x":…,"y":…}`, coordinates in the streamed
// display's pixels (its full native size, the `source` event's `w`×`h`; the
// video is that picture uniformly scaled), origin top left, `t_us` this Mac's
// monotonic clock in microseconds. Sent only to a viewer that opened `focus`.

/// The streamed display, for converting global coordinates to its pixels.
struct FocusGeometry: Equatable, Sendable {
    /// The display's frame in global display coordinates (points, origin at
    /// the main display's top left, y down: CGEvent, CGWindowList and AX).
    var display: CGRect
    /// The display's native size in pixels.
    var pixels: CGSize

    /// An AppKit point (origin at the main display's bottom left, y up) in
    /// global display coordinates; `mainHeight` is the main display's height in points.
    static func flipped(appKit point: CGPoint, mainHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainHeight - point.y)
    }

    /// An AppKit rect (NSWindow, NSScreen frames) in global display coordinates.
    static func flipped(appKit rect: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private var scale: CGSize {
        CGSize(width: display.width > 0 ? pixels.width / display.width : 0,
               height: display.height > 0 ? pixels.height / display.height : 0)
    }

    /// A global point in display pixels; nil when it is off this display.
    func point(_ global: CGPoint) -> CGPoint? {
        guard display.width > 0, display.height > 0, display.contains(global) else { return nil }
        return CGPoint(x: (global.x - display.minX) * scale.width, y: (global.y - display.minY) * scale.height)
    }

    /// A global rect in display pixels, clipped to the display; nil when none
    /// of it is on it. A zero-width rect (a caret) keeps its height.
    func rect(_ global: CGRect) -> CGRect? {
        guard display.width > 0, display.height > 0, !global.isNull, global.minX.isFinite, global.minY.isFinite,
              global.width.isFinite, global.height.isFinite else { return nil }
        let left = max(global.minX, display.minX), right = min(global.maxX, display.maxX)
        let top = max(global.minY, display.minY), bottom = min(global.maxY, display.maxY)
        guard right >= left, bottom >= top, left < display.maxX, top < display.maxY else { return nil }
        return CGRect(x: (left - display.minX) * scale.width, y: (top - display.minY) * scale.height,
                      width: (right - left) * scale.width, height: (bottom - top) * scale.height)
    }

    /// A rect in the captured picture's pixels (`captured` is that picture's
    /// size: the display scaled to the viewer's demand) in display pixels,
    /// clipped to the display.
    func captured(_ rect: CGRect, in captured: CGSize) -> CGRect? {
        guard captured.width > 0, captured.height > 0, !rect.isNull, !rect.isEmpty else { return nil }
        let sx = pixels.width / captured.width, sy = pixels.height / captured.height
        let scaled = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
        let clipped = scaled.intersection(CGRect(origin: .zero, size: pixels))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
}

/// The focused window: its CGWindowList number (stable while it lives) and
/// frame in global display coordinates.
struct FocusWindow: Equatable, Sendable {
    var id: UInt64
    var frame: CGRect
    /// The owning process (for the caret: that app's focused element).
    var pid: pid_t = 0
}

/// One focus event, as cmux-follow-cam's serde `Event` reads it.
struct FocusEvent: Equatable, Sendable {
    enum Signal: Equatable, Sendable {
        case source(w: Double, h: Double)
        case pointer(x: Double, y: Double)
        case caret(CGRect)
        case window(id: UInt64, CGRect)
        case damage(CGRect)
        case cut
    }

    var tUs: UInt64
    var signal: Signal

    /// The message: `t_us`, the `kind` tag, then its fields. Coordinates to a
    /// tenth of a pixel, never in exponent form or non-finite.
    var json: String {
        func n(_ value: Double) -> String { Self.number(value) }
        func box(_ r: CGRect) -> String { #""x":\#(n(r.minX)),"y":\#(n(r.minY)),"w":\#(n(r.width)),"h":\#(n(r.height))"# }
        let head = #"{"t_us":\#(tUs),"kind":"#
        switch signal {
        case let .source(w, h): return head + #""source","w":\#(n(w)),"h":\#(n(h))}"#
        case let .pointer(x, y): return head + #""pointer","x":\#(n(x)),"y":\#(n(y))}"#
        case let .caret(rect): return head + #""caret",\#(box(rect))}"#
        case let .window(id, rect): return head + #""window","id":\#(id),\#(box(rect))}"#
        case let .damage(rect): return head + #""damage",\#(box(rect))}"#
        case .cut: return head + #""cut"}"#
        }
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let tenth = min(max((value * 10).rounded() / 10, -1e9), 1e9)
        if tenth == tenth.rounded() { return String(Int64(tenth)) }
        return String(tenth)
    }
}

/// Screen damage between two sends: nearby rects merged into regions (a
/// terminal's changed rows become one), at most ``maximumRegions`` kept
/// however many frames arrive. The schema has one rect per message, so a
/// send takes the largest few regions rather than their union: a union of a
/// typed line and a menu bar clock would cover half the screen and point
/// the camera at nothing.
struct FocusDamage: Sendable {
    static let maximumRegions = 16
    /// Rects closer than this (pixels) are one region.
    static let gap: CGFloat = 32
    private var regions: [CGRect] = []

    var count: Int { regions.count }

    mutating func add(_ rects: [CGRect]) {
        for rect in rects where !rect.isNull && !rect.isEmpty && rect.width.isFinite && rect.height.isFinite {
            insert(rect)
        }
    }

    private mutating func insert(_ rect: CGRect) {
        var merged = rect
        var index = 0
        while index < regions.count {
            if regions[index].insetBy(dx: -Self.gap, dy: -Self.gap).intersects(merged) {
                merged = merged.union(regions.remove(at: index))
                index = 0
            } else {
                index += 1
            }
        }
        regions.append(merged)
        guard regions.count > Self.maximumRegions,
              let smallest = regions.indices.min(by: { area(regions[$0]) < area(regions[$1]) }) else { return }
        // Too many: the smallest joins the region nearest it.
        let small = regions.remove(at: smallest)
        guard let nearest = regions.indices.min(by: { distance(regions[$0], small) < distance(regions[$1], small) }) else { return }
        insert(small.union(regions.remove(at: nearest)))
    }

    /// The largest `limit` regions, largest first; the rest is dropped.
    mutating func drain(limit: Int) -> [CGRect] {
        defer { regions.removeAll() }
        return Array(regions.sorted { area($0) > area($1) }.prefix(limit))
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}

/// Where the focus signals come from, in global display coordinates (points,
/// top left origin). The live one reads CGEvent, CGWindowList and the
/// Accessibility API (``FocusSignalProducer/systemProbe()``); tests inject one.
protocol FocusProbe: Sendable {
    /// The mouse pointer.
    func pointer() -> CGPoint?
    /// The frontmost app's frontmost window (no Accessibility grant needed).
    func focusedWindow() -> FocusWindow?
    /// The text caret of the focused element; nil without the Accessibility
    /// grant or when the focused element has none.
    func caret() -> CGRect?
}

/// Samples the probe about 30 times a second and sends what changed, each
/// signal at its own rate: the pointer every tick (~30/s), the caret every
/// 2nd (~15/s), the window every 6th (~5/s), damage every 3rd (at most 3
/// regions: ≤ 30 messages/s). Once a second (and after a send failed, when
/// the channel opens) the source size, pointer, window and caret go again,
/// so a late or reconnected follower starts complete.
// crash-allow: state is read and written only under `lock`; ticks run one at a time on `queue`.
final class FocusSignalProducer: @unchecked Sendable {
    static let ticksPerSecond = 30
    static let caretEvery = 2
    static let windowEvery = 6
    static let damageEvery = 3
    static let damageRegionsPerSend = 3
    /// A pointer move shorter than this (display pixels) is not sent.
    static let pointerStep: CGFloat = 0.5

    private let probe: any FocusProbe
    private let geometry: @Sendable () -> FocusGeometry?
    private let send: @Sendable (String) -> Bool
    private let queue = DispatchQueue(label: "cmux.screen.focus", qos: .userInitiated)
    private let lock = NSLock()
    private var damage = FocusDamage()
    private var ticks = 0
    private var resync = true
    private var lastSource: CGSize?
    private var lastPointer: CGPoint?
    private var lastCaret: CGRect?
    private var lastWindow: (id: UInt64, rect: CGRect)?

    init(probe: any FocusProbe, geometry: @escaping @Sendable () -> FocusGeometry?, send: @escaping @Sendable (String) -> Bool) {
        self.probe = probe
        self.geometry = geometry
        self.send = send
    }

    /// One captured picture's changed rects, in that picture's pixels
    /// (`captured` its size). Any thread.
    func damage(_ rects: [CGRect], captured: CGSize) {
        guard let geometry = geometry() else { return }
        let converted = rects.compactMap { geometry.captured($0, in: captured) }
        guard !converted.isEmpty else { return }
        lock.withLock { damage.add(converted) }
    }

    /// This Mac's monotonic clock, in microseconds (every event's `t_us`).
    static func nowMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1000
    }

    /// One sample and send. Called one at a time (``run(channelOpen:)``, tests).
    func tick(now: UInt64) {
        lock.lock()
        let tick = ticks
        ticks += 1
        let full = resync || tick % Self.ticksPerSecond == 0
        lock.unlock()
        guard let geometry = geometry() else { return }
        var signals: [FocusEvent.Signal] = []
        let state = lock.withLock { (lastSource, lastPointer, lastCaret, lastWindow) }
        var next = state
        if full || state.0 != geometry.pixels {
            signals.append(.source(w: Double(geometry.pixels.width), h: Double(geometry.pixels.height)))
            next.0 = geometry.pixels
        }
        if let pointer = probe.pointer().flatMap(geometry.point),
           full || state.1.map({ hypot($0.x - pointer.x, $0.y - pointer.y) >= Self.pointerStep }) ?? true {
            signals.append(.pointer(x: Double(pointer.x), y: Double(pointer.y)))
            next.1 = pointer
        }
        if full || tick % Self.windowEvery == 0, let window = probe.focusedWindow(), let rect = geometry.rect(window.frame),
           full || state.3.map({ $0.id != window.id || $0.rect != rect }) ?? true {
            signals.append(.window(id: window.id, rect))
            next.3 = (window.id, rect)
        }
        if full || tick % Self.caretEvery == 0 {
            let caret = probe.caret().flatMap(geometry.rect)
            if let caret, full || caret != state.2 { signals.append(.caret(caret)) }
            next.2 = caret
        }
        if tick % Self.damageEvery == 0 {
            let regions = lock.withLock { damage.drain(limit: Self.damageRegionsPerSend) }
            signals += regions.map { .damage($0) }
        }
        for signal in signals where !send(FocusEvent(tUs: now, signal: signal).json) {
            // The channel is not open (yet): everything goes again once it is.
            lock.withLock { resync = true }
            return
        }
        lock.withLock {
            (lastSource, lastPointer, lastCaret, lastWindow) = next
            resync = false
        }
    }

    /// Samples until cancelled, off the caller's thread (AX and the window
    /// list are IPC). Stops early when the viewer never opens `focus` (an
    /// older viewer) within 10 s.
    func run(channelOpen: @escaping @Sendable () -> Bool) async {
        var waited = 0
        var opened = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1000 / Self.ticksPerSecond)) // focus sampling period
            guard channelOpen() else {
                waited += 1
                if !opened, waited > 10 * Self.ticksPerSecond { return }
                continue
            }
            opened = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    self.tick(now: Self.nowMicroseconds())
                    continuation.resume()
                }
            }
        }
    }
}

/// A screen source that reports which parts of each captured picture
/// changed: rects in that picture's pixels (top left origin) and its size.
/// The one damage feed (ScreenCaptureKit's `dirtyRects`); any thread.
protocol ScreenDamageSource: AnyObject {
    var onDamage: (@Sendable ([CGRect], CGSize) -> Void)? { get set }
}
