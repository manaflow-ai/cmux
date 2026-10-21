public import Foundation

/// How agent work shows on a row, tab or transcript line (WORKING-LOOK, Leo 2026-10-20: seventeen
/// running sessions with a spinner each "reads as noise"; "isn't this mildly ugly?"). Applies where
/// a status icon set draws work as the turning arc (the Codex-like default and the spinner sets);
/// loading (a page, a command) keeps its spinner. Web pages get it as `data-working-look`
/// (`WebTheme.workingLook`). Under Reduce Motion or the static look nothing moves, whatever the look.
public nonisolated enum StatusWorkingLook: String, Sendable, CaseIterable, TunableChoice {
    /// A small dot in the theme accent that breathes, one breath per Motion `breath` period, on the
    /// shared clock: many working rows breathe as one (the default).
    case breathe
    /// The same dot held still; on web pages the working row's words shimmer.
    case shimmer
    /// The turning arc (before 2026-10-21).
    case spinner

    /// The Debug Settings switch (section "Status Indicators").
    public static let tunable = Tunable<StatusWorkingLook>.choice(
        "status.working", .status, "Working look",
        help: "How agent work shows on rows, tabs and transcript lines: a breathing accent dot (default), a still dot with the row's words shimmering (web pages), or the spinner.",
        default: .breathe, code: "StatusWorkingLook.tunable")

    public var tunableTitle: String {
        switch self {
        case .breathe: String(localized: "statusWorkingLook.breathe", defaultValue: "Breathing Dot", bundle: .module)
        case .shimmer: String(localized: "statusWorkingLook.shimmer", defaultValue: "Shimmer", bundle: .module)
        case .spinner: String(localized: "statusWorkingLook.spinner", defaultValue: "Spinner", bundle: .module)
        }
    }

    /// `plan` restyled for this look: agent work drawn as the turning arc becomes the accent dot,
    /// breathing for `breathe` and still for `shimmer`. Anything else is unchanged.
    func restyle(_ plan: StatusIndicatorPlan, for state: StatusIndicatorState) -> StatusIndicatorPlan {
        guard self != .spinner, state.isWorking, state.progress == nil, plan.glyph == .arc else { return plan }
        return StatusIndicatorPlan(glyph: .dot, animation: self == .breathe ? .breathe : nil, tint: .working)
    }
}
