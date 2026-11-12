public import AppKit
public import CmuxNextDesignTokens

/// The one corner curve tabs, the tab bar's `+ ⌄` and the sidebar's row fills share (Lucas 2026-11-12: "Sidebar row
/// roundness must be exactly the same as tab roundness"; tab roundness close to Chrome's, Lawrence prefers Helium).
/// `helium`, the default, is Helium's and Chrome's tab: a circular-arc rounded rect (SkRRect). `squircle` is Apple's
/// continuous curve, to compare beside Helium.
public nonisolated enum TabCornerCurve: String, Sendable, CaseIterable, TunableChoice {
    case helium
    case squircle

    public var tunableTitle: String {
        switch self {
        case .helium: "Helium: circular arcs"
        case .squircle: "Squircle: continuous"
        }
    }

    /// The layer curve this look draws with.
    public var layerCurve: CALayerCornerCurve { self == .helium ? .circular : .continuous }

    public static let tunable = Tunable<TabCornerCurve>.choice(
        "tabs.cornerCurve", .shape, "Tab and row corner curve",
        help: "The corner curve tabs, the tab bar's + and the sidebar rows share: Helium's circular arcs or Apple's squircle.",
        default: .helium, code: "TabCornerCurve.tunable")
}

public extension Metrics {
    /// The corner curve of a tab, the tab bar's `+ ⌄` and a sidebar row fill (``TabCornerCurve``): one, so a row and a
    /// tab round the same.
    @MainActor static var tabCornerCurve: CALayerCornerCurve { TabCornerCurve.tunable.value.layerCurve }
}
