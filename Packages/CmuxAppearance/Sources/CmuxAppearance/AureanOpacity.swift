import Foundation

/// The φ-derived opacity ladder that encodes depth in the Aurean theme.
///
/// Depth is expressed **only** through opacity — never drop shadows or bevels (the
/// single exception is the window's own near-black cast shadow, which lives outside
/// this theme). Each stop is `1/φⁿ`, matching the design tokens.
///
/// ```swift
/// let border = palette.text.opacity(AureanOpacity.border.value) // sand @ 0.236
/// ```
public enum AureanOpacity: Double, Sendable, CaseIterable {
    /// Fully opaque (`1.0`) — solid fills.
    case solid = 1.0
    /// `1/φ` (`0.618`) — organic primary detail.
    case organic = 0.618
    /// `1/φ²` (`0.382`) — secondary content.
    case secondary = 0.382
    /// `1/φ³` (`0.236`) — standard rules and borders.
    case border = 0.236
    /// `1/φ⁴` (`0.145`) — faint trails and wash gradients.
    case faint = 0.145
    /// `0.090` — telemetry "dust" and ghost rules.
    case dust = 0.090
    /// `0.045` — the faintest pane-header wash.
    case whisper = 0.045

    /// The raw opacity value in the `0...1` range.
    public var value: Double { rawValue }
}
