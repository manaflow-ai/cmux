public import Foundation
public import CmuxNextDesignTokens

/// How agent work shows on a row, tab or transcript line (WORKING-LOOK). The spinner is the default
/// (Leo 2026-10-21: "WHO BROUGHT BACK BLINKING ICONS? WE SAID NO BLINKING. WE SAID SPINNER."); the
/// still dot stays as a Debug choice. The breathing dot of 2026-10-20 (#22826) is gone for good
/// (Leo: "we need to GUARANTEE the breathing dot doesn't come back"); a stored `breathe` reads as
/// the default, the spinner (`NoBreathingDotTests`). Applies where a status icon set
/// draws work as the turning arc (the Codex-like default and the spinner sets); loading (a page, a
/// command) keeps its spinner. Web pages get it as `data-working-look` (`WebTheme.workingLook`).
/// Under Reduce Motion or the static look nothing moves, whatever the look.
public nonisolated enum StatusWorkingLook: String, Sendable, CaseIterable, TunableChoice {
    /// A still dot in the theme accent; on web pages the working row's words shimmer. Debug only.
    case shimmer
    /// The turning arc (the default).
    case spinner

    /// The Debug Settings switch (section "Status Indicators").
    public static let tunable = Tunable<StatusWorkingLook>.choice(
        "status.working", .status, "Working look",
        help: "How agent work shows on rows, tabs and transcript lines: the spinner (default), or a still accent dot with the row's words shimmering (web pages).",
        default: .spinner, code: "StatusWorkingLook.tunable")

    public var tunableTitle: String {
        switch self {
        case .shimmer: String(localized: "statusWorkingLook.shimmer", defaultValue: "Shimmer", bundle: .module)
        case .spinner: String(localized: "statusWorkingLook.spinner", defaultValue: "Spinner", bundle: .module)
        }
    }

    /// `plan` restyled for this look: agent work drawn as the turning arc becomes the still accent
    /// dot for `shimmer`. Anything else is unchanged.
    func restyle(_ plan: StatusIndicatorPlan, for state: StatusIndicatorState) -> StatusIndicatorPlan {
        guard self != .spinner, state.isWorking, state.progress == nil, plan.glyph == .arc else { return plan }
        return StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .working)
    }
}
