public import Foundation
public import CmuxNextDesignTokens

/// How agent work shows on a row, tab or transcript line (WORKING-LOOK). The spinner is the default
/// (Leo 2026-10-21: "WHO BROUGHT BACK BLINKING ICONS? WE SAID NO BLINKING. WE SAID SPINNER."); the
/// breathing and still dots of 2026-10-20 stay as Debug choices. Applies where a status icon set
/// draws work as the working spinner (the Codex-like default and the spinner sets); loading (a page, a
/// command) keeps its spinner. Web pages get it as `data-working-look` (`WebTheme.workingLook`).
/// Under Reduce Motion or the static look nothing moves, whatever the look.
public nonisolated enum StatusWorkingLook: String, Sendable, CaseIterable, TunableChoice {
    /// A small dot in the theme accent that breathes, one breath per Motion `breath` period, on the
    /// shared clock: many working rows breathe as one. Debug only: it blinks.
    case breathe
    /// The same dot held still; on web pages the working row's words shimmer.
    case shimmer
    /// The working spinner's turning arc (the default, `StatusIndicatorPlan.working`).
    case spinner

    /// The Debug Settings switch (section "Status Indicators").
    public static let tunable = Tunable<StatusWorkingLook>.choice(
        "status.working", .status, "Working look",
        help: "How agent work shows on rows, tabs and transcript lines: the spinner (default), a breathing accent dot, or a still dot with the row's words shimmering (web pages).",
        default: .spinner, code: "StatusWorkingLook.tunable")

    public var tunableTitle: String {
        switch self {
        case .breathe: String(localized: "statusWorkingLook.breathe", defaultValue: "Breathing Dot", bundle: .module)
        case .shimmer: String(localized: "statusWorkingLook.shimmer", defaultValue: "Shimmer", bundle: .module)
        case .spinner: String(localized: "statusWorkingLook.spinner", defaultValue: "Spinner", bundle: .module)
        }
    }

    /// `plan` restyled for this look: agent work drawn as the working spinner becomes the accent dot,
    /// breathing for `breathe` and still for `shimmer`. Anything else is unchanged.
    func restyle(_ plan: StatusIndicatorPlan, for state: StatusIndicatorState) -> StatusIndicatorPlan {
        guard self != .spinner, state.isWorking, state.progress == nil, plan.glyph == StatusIndicatorPlan.workingGlyph else { return plan }
        return StatusIndicatorPlan(glyph: .dot, animation: self == .breathe ? .breathe : nil, tint: .working)
    }
}
