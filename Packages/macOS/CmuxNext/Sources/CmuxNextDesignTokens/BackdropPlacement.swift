public import CoreGraphics
import Foundation

/// Where one background picture lies in its window or pane (`appearance.backgroundPlacement`,
/// Leo 2026-11-22: "we also want people to be able to reposition the images easily").
///
/// The math is Rust's (`cmux-config` `backdrop_placement`, the spec and its tests); this is its
/// mirror for drawing, because the art layer lays out on every resize and a call through the app
/// FFI per frame buys nothing. `BackdropPlacementTests` checks it against the table the Rust tests
/// write (`cmux-tui/crates/cmux-config/tests/fixtures/backdrop-placement-cases.json`).
///
/// Rects here use a top-left origin, y growing down, like the Rust and the web; ``layerFrame(image:in:)``
/// flips them for a bottom-left layer.
public nonisolated struct BackdropPlacement: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        /// Cover the view, keeping the aspect ratio: today's look.
        case fill
        /// Show the whole picture.
        case fit
        /// The picture at its own size.
        case center
        /// Cover the view, ignoring the aspect ratio.
        case stretch
    }

    public static let zoomRange: ClosedRange<Double> = 1...4

    public var mode: Mode
    /// 0 (left) to 1 (right).
    public var x: Double
    /// 0 (top) to 1 (bottom).
    public var y: Double
    /// 1 to 4.
    public var zoom: Double

    /// Clamps the anchor to 0...1 and the zoom to ``zoomRange`` (NaN is the default).
    public init(mode: Mode = .fill, x: Double = 0.5, y: Double = 0.5, zoom: Double = 1) {
        self.mode = mode
        self.x = x.isNaN ? 0.5 : min(max(x, 0), 1)
        self.y = y.isNaN ? 0.5 : min(max(y, 0), 1)
        self.zoom = zoom.isNaN ? 1 : min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// Unset: the picture fills the view, centered (Core Animation's `resizeAspectFill`).
    public static let centeredFill = Self()

    /// Whether this draws exactly as an unset placement does.
    public var isCenteredFill: Bool { self == .centeredFill }

    /// Reads one placement text (`fill`, `fit 0.25 0.5`, `fill 0.3 0.7 2`); out-of-range values
    /// are refused (Rust `Placement::parse`).
    public init?(text: String) {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first, let mode = Mode(rawValue: first) else { return nil }
        // Decimal only, as Rust's `f64` reads: Swift's `Double` also takes hex (`0x1p0`), which Rust refuses.
        func number(_ part: String) -> Double? {
            guard part.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }) else { return nil }
            return Double(part).flatMap { $0.isFinite ? $0 : nil }
        }
        func unit(_ part: String) -> Double? { number(part).flatMap { (0...1).contains($0) ? $0 : nil } }
        switch parts.count {
        case 1: self.init(mode: mode)
        case 3:
            guard let x = unit(parts[1]), let y = unit(parts[2]) else { return nil }
            self.init(mode: mode, x: x, y: y)
        case 4:
            guard let x = unit(parts[1]), let y = unit(parts[2]),
                  let zoom = number(parts[3]), Self.zoomRange.contains(zoom) else { return nil }
            self.init(mode: mode, x: x, y: y, zoom: zoom)
        default: return nil
        }
    }

    /// The shortest text that reads back the same (Rust `Placement::to_text`).
    public var text: String {
        func number(_ value: Double) -> String {
            var text = String(format: "%.3f", value)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text == "-0" ? "0" : text
        }
        var out = mode.rawValue
        if x != 0.5 || y != 0.5 || zoom != 1 { out += " \(number(x)) \(number(y))" }
        if zoom != 1 { out += " \(number(zoom))" }
        return out
    }

    /// Where the whole picture is drawn in a `view`-sized view (top-left origin); it may run past
    /// the edges. Nil when either has no area (Rust `placement_rect`).
    public func rect(image: CGSize, view: CGSize) -> CGRect? {
        func positive(_ value: CGFloat) -> Bool { value.isFinite && value > 0 }
        guard positive(image.width), positive(image.height), positive(view.width), positive(view.height) else { return nil }
        var size: CGSize
        switch mode {
        case .fill, .fit:
            let sx = view.width / image.width
            let sy = view.height / image.height
            let scale = mode == .fill ? max(sx, sy) : min(sx, sy)
            size = CGSize(width: image.width * scale, height: image.height * scale)
        case .center: size = image
        case .stretch: size = view
        }
        size = CGSize(width: size.width * zoom, height: size.height * zoom)
        return CGRect(x: (view.width - size.width) * x, y: (view.height - size.height) * y,
                      width: size.width, height: size.height)
    }

    /// The part of the view the picture covers and the part of the picture drawn there (unit,
    /// top-left origin); nil when it misses the view (Rust `visible`).
    public func visible(image: CGSize, view: CGSize) -> (frame: CGRect, contents: CGRect)? {
        guard let drawn = rect(image: image, view: view) else { return nil }
        let frame = drawn.intersection(CGRect(origin: .zero, size: view))
        guard !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
        let contents = CGRect(x: (frame.minX - drawn.minX) / drawn.width, y: (frame.minY - drawn.minY) / drawn.height,
                              width: frame.width / drawn.width, height: frame.height / drawn.height)
        return (frame, contents)
    }

    /// The art layer's frame and `contentsRect` in a bottom-left `bounds` (an unflipped AppKit
    /// view's layer, whose unit space starts at the bottom-left too).
    public func layerFrame(image: CGSize, in bounds: CGRect) -> (frame: CGRect, contentsRect: CGRect)? {
        guard let shown = visible(image: image, view: bounds.size) else { return nil }
        let frame = CGRect(x: bounds.minX + shown.frame.minX, y: bounds.maxY - shown.frame.maxY,
                           width: shown.frame.width, height: shown.frame.height)
        let contents = CGRect(x: shown.contents.minX, y: 1 - shown.contents.maxY,
                              width: shown.contents.width, height: shown.contents.height)
        return (frame, contents)
    }

    /// The whole drawn picture in a bottom-left `bounds` (the glass lens's image rect).
    public func drawnFrame(image: CGSize, in bounds: CGRect) -> CGRect? {
        guard let drawn = rect(image: image, view: bounds.size) else { return nil }
        return CGRect(x: bounds.minX + drawn.minX, y: bounds.maxY - drawn.maxY, width: drawn.width, height: drawn.height)
    }

    /// The placement after the picture is dragged `dx`, `dy` points (right and down positive):
    /// it follows the pointer until an edge would show (Rust `dragged`).
    public func dragged(image: CGSize, view: CGSize, dx: Double, dy: Double) -> Self {
        guard let drawn = rect(image: image, view: view) else { return self }
        func step(_ anchor: Double, _ delta: Double, _ room: Double) -> Double {
            abs(room) < 1e-9 ? anchor : min(max(anchor + delta / room, 0), 1)
        }
        return Self(mode: mode, x: step(x, dx, Double(view.width - drawn.width)),
                    y: step(y, dy, Double(view.height - drawn.height)), zoom: zoom)
    }

    /// This placement zoomed by `factor` (a pinch's magnification step, or a scroll's), clamped.
    public func zoomed(by factor: Double) -> Self {
        Self(mode: mode, x: x, y: y, zoom: zoom * factor)
    }

    /// The placements `appearance.backgroundPlacement` holds, by picture id; entries that do not
    /// read are left out.
    public static func map(_ raw: [String: String]) -> [String: Self] {
        var out: [String: Self] = [:]
        for (id, text) in raw where !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let placement = Self(text: text) { out[id] = placement }
        }
        return out
    }

    /// The id `appearance.backgroundPlacement` keys a shown picture by (Rust `placement_key`): a
    /// dynamic wallpaper's moment (`system:PATH|frame:N|dark`) is its file, so a placement stays
    /// as its frames change; a Light and Dark pair, a mode, a shuffle, `none` or an empty id is
    /// no one picture (nil). Any other id is its own key.
    public static func key(picture id: String) -> String? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !["none", "daily", "appearance", "schedule"].contains(id),
              !id.hasPrefix("folder:"), !id.hasPrefix("appearance:") else { return nil }
        guard id.hasPrefix("system:"), let cut = id.range(of: "|frame:", options: .backwards),
              cut.lowerBound >= id.index(id.startIndex, offsetBy: "system:".count) else { return id }
        let moment = id[cut.upperBound...]
        let frame = moment.hasSuffix("|light") ? moment.dropLast(6) : moment.hasSuffix("|dark") ? moment.dropLast(5) : nil
        guard let frame, !frame.isEmpty, frame.allSatisfy({ $0.isASCII && $0.isNumber }) else { return id }
        return String(id[..<cut.lowerBound])
    }
}
