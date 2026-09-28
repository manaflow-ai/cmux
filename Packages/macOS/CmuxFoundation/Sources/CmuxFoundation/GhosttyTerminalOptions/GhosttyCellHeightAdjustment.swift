import Foundation

/// An `adjust-cell-height` value: extra line height added to the font's own,
/// as a percentage (`8%`) or a number of pixels (`2`). Negative values tighten
/// the lines.
public enum GhosttyCellHeightAdjustment: Equatable, Sendable {
    case percent(Int)
    case pixels(Int)

    /// No adjustment, Ghostty's default.
    public static let unadjusted = GhosttyCellHeightAdjustment.percent(0)

    /// Parses Ghostty's `20%`, `-15%`, or `2` spelling.
    public init?(configValue: String) {
        let value = configValue.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("%") {
            guard let percent = Int(value.dropLast().trimmingCharacters(in: .whitespaces)) else { return nil }
            self = .percent(percent)
        } else if let pixels = Int(value) {
            self = .pixels(pixels)
        } else {
            return nil
        }
    }

    /// The percentage the line height row steps from. A pixel value has no
    /// percentage equivalent without the font's metrics, so it steps from 0%.
    public var percentValue: Int {
        guard case .percent(let percent) = self else { return 0 }
        return percent
    }

    /// Ghostty's spelling: `8%` or `2`.
    public var configValue: String {
        switch self {
        case .percent(let percent): return "\(percent)%"
        case .pixels(let pixels): return String(pixels)
        }
    }
}
