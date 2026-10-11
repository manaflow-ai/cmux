public import AppKit

/// `appearance.borders` in cmux.json: `default` draws the app's borders,
/// hairlines and separators; `none` removes every one of them.
public nonisolated enum BorderMode: String, Sendable, CaseIterable, Codable, TunableChoice {
    case `default`
    case none

    public var tunableTitle: String {
        switch self {
        case .default: "Default"
        case .none: "None"
        }
    }
}

/// The one switch every border, hairline and separator in the app goes
/// through (pane borders, the focus ring, divider lines, tab, strip,
/// sidebar and palette separators, panel and badge strokes). A value, so
/// the rule is tested without views; `Borders.current` is the live one.
public nonisolated struct Borders: Sendable, Equatable {
    public var mode: BorderMode

    public init(mode: BorderMode) {
        self.mode = mode
    }

    /// Whether lines draw at all.
    public var drawsLines: Bool { mode == .default }

    /// The width a border of `width` points draws with: 0 under `none`.
    public func width(_ width: CGFloat) -> CGFloat { drawsLines ? width : 0 }

    /// The color a separator or border of `color` draws with: clear under
    /// `none`, so a separator view keeps its space (spacing and alignment
    /// do not move) and draws nothing.
    public func color(_ color: NSColor) -> NSColor { drawsLines ? color : .clear }
}

/// The live switch: a Debug Settings override, else cmux.json. Reading it
/// in an observed scope tracks the setting.
extension Borders {
    public nonisolated static let tunable = Tunable<BorderMode>.choice(
        "appearance.borders", .shape, "Borders",
        help: "None removes every border, hairline and separator (overrides appearance.borders in cmux.json).",
        default: .default, code: "Borders.tunable")

    @MainActor public static var current: Borders { Borders(mode: tunable.override ?? DesignSettings.shared.borders) }
    @MainActor public static var drawsLines: Bool { current.drawsLines }
    @MainActor public static func width(_ width: CGFloat) -> CGFloat { current.width(width) }
    @MainActor public static func color(_ color: NSColor) -> NSColor { current.color(color) }
}
