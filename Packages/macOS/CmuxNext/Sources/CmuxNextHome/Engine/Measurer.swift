public import CoreGraphics
import Synchronization

/// Measurement cache key (MessagesLab: id, part, version, width).
nonisolated struct MeasureKey: Hashable, Sendable {
    var rowKey: String
    var part: Int
    var version: Int
    /// `TranscriptGeometry.maxTextWidth` in whole points.
    var width: Int
    /// Font size in tenths of a point.
    var font: Int
}

/// Bubble sizes keyed by ``MeasureKey``, bounded LRU. CoreText measurement is
/// thread-safe, so pages are measured off the main actor before they join the
/// window; rows that are not measured yet use ``estimate`` and are measured
/// before they come within two screens of the viewport.
nonisolated final class Measurer: Sendable {
    static let capacity = 24_000

    private struct State {
        var sizes: [MeasureKey: CGSize] = [:]
        var order: [MeasureKey] = []
        var head = 0
        var labels: [String: CGFloat] = [:]
        var measured = 0
    }
    private let state = Mutex(State())

    init() {}

    static func key(_ message: HomeMessage, part: Int, geometry: TranscriptGeometry) -> MeasureKey {
        MeasureKey(rowKey: message.rowKey, part: part, version: message.contentVersion,
                   width: Int(geometry.maxTextWidth), font: Int((geometry.fontSize * 10).rounded()))
    }

    var count: Int { state.withLock { $0.sizes.count } }
    var measuredCount: Int { state.withLock { $0.measured } }

    func cached(_ key: MeasureKey) -> CGSize? { state.withLock { $0.sizes[key] } }

    /// The part's bubble size, measuring now on a miss.
    func size(of part: HomePart, key: MeasureKey, geometry: TranscriptGeometry) -> CGSize {
        if let hit = cached(key) { return hit }
        let size = Self.measure(part, geometry: geometry)
        store(size, for: key)
        return size
    }

    /// Measures every part of `messages` (any thread).
    func measure(_ messages: [HomeMessage], geometry: TranscriptGeometry) {
        for message in messages where message.retractedAt == nil {
            for (index, part) in message.parts.enumerated() {
                _ = size(of: part, key: Self.key(message, part: index, geometry: geometry), geometry: geometry)
            }
        }
    }

    private func store(_ size: CGSize, for key: MeasureKey) {
        state.withLock { s in
            if s.sizes.updateValue(size, forKey: key) == nil { s.order.append(key) }
            s.measured += 1
            let live = s.order.count - s.head
            guard live > Self.capacity else { return }
            // bounded: drop the oldest quarter
            let drop = Self.capacity / 4
            for k in s.order[s.head..<(s.head + drop)] { s.sizes[k] = nil }
            s.head += drop
            if s.head > Self.capacity {
                s.order.removeFirst(s.head)
                s.head = 0
            }
        }
    }

    /// Width of a one-line label (cached by text, size and weight).
    func labelWidth(_ text: String, size: CGFloat, emphasized: Bool) -> CGFloat {
        let key = "\(emphasized ? 1 : 0)|\(size)|\(text)"
        if let hit = state.withLock({ $0.labels[key] }) { return hit }
        let width = TextFormatter.lineWidth(text, size: size, emphasized: emphasized)
        state.withLock { s in
            if s.labels.count > 4096 { s.labels.removeAll(keepingCapacity: true) }
            s.labels[key] = width
        }
        return width
    }

    static func measure(_ part: HomePart, geometry g: TranscriptGeometry) -> CGSize {
        switch part {
        case .text(let text, let mentions):
            let t = TextFormatter.measure(text, mentions: mentions, fontSize: g.fontSize, lineHeight: g.lineHeight,
                                          maxWidth: g.maxTextWidth)
            let height = t.height + 2 * g.insetY
            return CGSize(width: max(height, min(g.maxBubbleWidth, t.width + 2 * g.insetX)), height: height)
        case .fallback(let text):
            return measure(.text(text), geometry: g)
        case .work:
            return CGSize(width: g.workCardWidth, height: g.workCardHeight)
        }
    }

    /// A size from character counts; replaced by the measurement before the row is seen.
    static func estimate(_ part: HomePart, geometry g: TranscriptGeometry) -> CGSize {
        let text: String
        switch part {
        case .text(let value, _), .fallback(let value): text = value
        case .work: return measure(part, geometry: g)
        }
        let charWidth = g.fontSize * 0.52
        var lines = 0
        var widest: CGFloat = 0
        var run = 0
        func close() {
            let w = CGFloat(run) * charWidth
            lines += max(1, Int((w / g.maxTextWidth).rounded(.up)))
            widest = max(widest, min(g.maxTextWidth, w))
            run = 0
        }
        for unit in text.utf16 { if unit == 10 { close() } else { run += 1 } }
        close()
        let height = CGFloat(lines) * g.lineHeight + 2 * g.insetY
        return CGSize(width: max(height, min(g.maxBubbleWidth, widest + 2 * g.insetX)), height: height)
    }
}
