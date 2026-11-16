import CmuxNextDesign
import CoreGraphics

/// Debug Settings tunables of the vertical tab list (`VerticalTabListView`). The defaults come from
/// the density tokens, so the list follows Compact and Comfortable like the strip.
nonisolated enum VerticalTabTunables {
    private static func points(_ name: String, _ label: String, help: String, range: ClosedRange<Double> = 0...64,
                               derive: @escaping @MainActor @Sendable () -> CGFloat) -> ComputedTunable {
        ComputedTunable("tabs.vertical.\(name)", .tabs, label, help: help, range: range, code: "VerticalTabTunables.\(name)", derive: derive)
    }

    /// Edge's and Chrome's expanded vertical tabs are about 240 points wide.
    static let expandedWidth = points("expandedWidth", "Vertical tabs width", help: "Width of the vertical tab list showing titles.",
                                      range: 120...480) { (Metrics.tabMaxWidth + 2 * Metrics.space5).rounded() }
    /// One icon with the row's padding on both sides.
    static let collapsedWidth = points("collapsedWidth", "Collapsed vertical tabs width", help: "Width of the vertical tab list collapsed to icons.",
                                       range: 28...96) { (Metrics.tabHeight + 2 * Metrics.space2).rounded() }
    static let rowSpacing = points("rowSpacing", "Vertical tab row gap", help: "Gap between rows of the vertical tab list.") { Metrics.space1 / 2 }
    static let groupLineWidth = points("groupLineWidth", "Vertical group line", help: "Width of the line joining a group's tabs in the vertical tab list.",
                                       range: 1...8) { 2 }
    static let hoverExpandDelay = Tunable<Double>.number(
        "tabs.vertical.hoverExpandDelay", .tabs, "Vertical tabs hover delay",
        help: "How long the pointer rests on a collapsed vertical tab list before it shows titles.",
        default: 0.3, range: 0...2, step: 0.05, unit: .seconds, code: "VerticalTabTunables.hoverExpandDelay")

    static var all: [TunableDescriptor] {
        [expandedWidth, collapsedWidth, rowSpacing, groupLineWidth].map(\.descriptor)
            + [hoverExpandDelay.descriptor, VerticalNoColorGroupLook.tunable.descriptor]
    }
}

/// How a tab group with no color still reads as a group in the vertical tab list (`tabs.vertical.noColorGroup`), as the
/// sidebar's `sidebar.noColorGroup` does. Leo 2026-11-05: "if you're gonna allow the no color option ... you might as
/// well have it be at least slightly distinguishing from, like, literally depicting it as if it were unhovered."
nonisolated enum VerticalNoColorGroupLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// One neutral pane (the theme's `sidebarStep`) behind the header and its tabs, with the `group` role's rim.
    case rimmed
    /// The pane alone, no rim.
    case pane
    /// Nothing: the header and tabs draw as plain rows (the look before).
    case plain

    var tunableTitle: String {
        switch self {
        case .rimmed: "Pane with a rim"
        case .pane: "Faint pane"
        case .plain: "Plain rows"
        }
    }

    static let tunable = Tunable<VerticalNoColorGroupLook>.choice(
        "tabs.vertical.noColorGroup", .tabs, "Vertical group with no color",
        help: "How a tab group with no color reads as a group in the vertical tab list: a faint neutral pane behind its header and tabs, or plain rows.",
        default: .rimmed, code: "VerticalNoColorGroupLook.tunable")
}
