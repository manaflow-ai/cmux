import Foundation

/// An `adjust-cell-height` value: extra line height added to the font's own,
/// as a percentage (`8%`, `12.5%`) or a number of device pixels (`2`).
/// Negative values tighten the lines.
public enum GhosttyCellHeightAdjustment: Equatable, Sendable {
    case percent(Double)
    case pixels(Int)

    /// No adjustment, Ghostty's default.
    public static let unadjusted = GhosttyCellHeightAdjustment.percent(0)

    /// Parses Ghostty's `20%`, `-12.5%`, or `2` spelling. Like Ghostty, only
    /// the ends of the value are trimmed, so `15 %` is invalid.
    public init?(configValue: String) {
        let value = configValue.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("%") {
            guard let percent = Double(value.dropLast()), percent.isFinite else { return nil }
            self = .percent(percent)
        } else if let pixels = Int(value) {
            self = .pixels(pixels)
        } else {
            return nil
        }
    }

    /// The adjustment one stepper step away: 2% for a percentage, 1 pixel
    /// for a pixel value, so a value set in a config file keeps its unit.
    public func stepped(by steps: Int) -> GhosttyCellHeightAdjustment {
        switch self {
        case .percent(let percent): return .percent((percent / 2).rounded() * 2 + Double(steps * 2))
        case .pixels(let pixels):
            let (sum, overflow) = pixels.addingReportingOverflow(steps)
            return .pixels(overflow ? (steps > 0 ? .max : .min) : sum)
        }
    }

    /// Ghostty's spelling: `8%`, `12.5%`, or `2`.
    public var configValue: String {
        switch self {
        case .percent(let percent):
            if percent == percent.rounded(), let integer = Int(exactly: percent) {
                return "\(integer)%"
            }
            return "\(percent)%"
        case .pixels(let pixels):
            return String(pixels)
        }
    }
}
