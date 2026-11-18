/// A list's content cut into bands of one `pitch` from `origin` (the macOS vertical tab list's row layers: one row and
/// its spacing each), with no AppKit or UIKit: which bands a viewport shows, and which ones a scroll step reveals. A
/// band is drawn once when it comes into view; a scroll moves the drawn ones.
public struct VisibleBands: Equatable, Sendable {
    public var pitch: Double
    public var origin: Double

    public init(pitch: Double, origin: Double) {
        self.pitch = max(1, pitch)
        self.origin = origin
    }

    /// The band content `y` falls in.
    public func band(_ y: Double) -> Int { Int(((y - origin) / pitch).rounded(.down)) }

    /// Band `index`'s top and bottom.
    public func span(_ index: Int) -> ClosedRange<Double> {
        let top = origin + Double(index) * pitch
        return top...(top + pitch)
    }

    /// The bands of `minY..<maxY` and `margin` more each side, within content `0..<contentHeight`; nil for none.
    public func shown(minY: Double, maxY: Double, contentHeight: Double, margin: Int = 1) -> ClosedRange<Int>? {
        guard maxY > minY, contentHeight > 0 else { return nil }
        let first = max(band(0), band(minY) - margin)
        let last = min(band(contentHeight - 0.5), band(max(minY, maxY - 0.5)) + margin)
        return first <= last ? first...last : nil
    }

    /// The shown bands of `minY..<maxY` (a changed row's frame), clamped to `shown`.
    public func touching(minY: Double, maxY: Double, in shown: ClosedRange<Int>?) -> ClosedRange<Int>? {
        guard let shown, maxY > minY else { return nil }
        let first = max(shown.lowerBound, band(minY)), last = min(shown.upperBound, band(maxY - 0.5))
        return first <= last ? first...last : nil
    }

    /// The bands in `new` and not in `old`: what a scroll from `old` to `new` draws.
    public static func revealed(from old: ClosedRange<Int>?, to new: ClosedRange<Int>?) -> [Range<Int>] {
        guard let new else { return [] }
        guard let old else { return [Range(new)] }
        return VisibleWindow.change(from: Range(old), to: Range(new)).added
    }
}
