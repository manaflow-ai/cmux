public import CoreGraphics

/// `appearance.focusIndicator` in cmux.json: what marks the focused pane
/// when more than one shows. `border` draws the focus ring, `tabs` draws
/// the other panes' tabs subtler (a cue that needs no colored border, so it
/// also works with `appearance.borders` none), `both` does both, `none`
/// neither.
public nonisolated enum FocusIndicator: String, Sendable, CaseIterable, Codable, TunableChoice {
    case border
    case tabs
    case both
    case none

    /// Whether the focus ring may draw (`focusRing.*` still decides how).
    public var marksBorder: Bool { self == .border || self == .both }
    /// Whether unfocused panes' tabs draw subtler.
    public var marksTabs: Bool { self == .tabs || self == .both }

    public var tunableTitle: String {
        switch self {
        case .border: "Border"
        case .tabs: "Tabs"
        case .both: "Both"
        case .none: "None"
        }
    }
}
