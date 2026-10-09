public import Foundation

/// Status icon candidate sets (cx-kxa2, Lawrence 2026-10-08: "make sure we
/// have better notif icons for osc 7501 things ... make sure i can try a
/// bunch of different icons so we can search for the best one together").
/// A DEV and NIGHTLY switch in Debug Settings (section "Status Indicators")
/// and in the Debug menu ("Status Icons"); it restyles every indicator
/// (sidebar rows, group headers, tab icon slots and badges) live. Each set
/// marks working, blocked (with the OSC 7501 kind: permission, question,
/// auth), done and error; idle draws nothing. Loading (busy, paused) and
/// known progress keep the loading style's marks. Colors are theme roles
/// only. The default stays `current` until Lawrence picks.
public nonisolated enum StatusIconSet: String, Sendable, CaseIterable, TunableChoice {
    /// Today's marks: working dots, a still attention dot, a danger dot, a check.
    case current
    /// Pictures: a sparkle, a raised hand, a speech bubble with ?, a key, a check, x in a circle.
    case shapes
    /// Outlined rings with a small mark inside; done is a filled disc.
    case rings
    /// Filled discs with the mark cut out: !, ?, key, check, x.
    case badges
    /// Waving bars for work; bare marks (!, ?, key, check, x) for the rest.
    case bars
    /// Minimal pips: color and a tiny shape only (filled, hollow, diamond).
    case pips
    /// Road signs: warning triangles for blocked, an octagon for error.
    case signs
    /// Monograms cut out of rounded squares: P, Q, A, !.
    case letters
    /// Filled SF Symbols: hand.raised, questionmark.bubble, key, checkmark.circle, xmark.octagon.
    case symbols
    /// Outlined SF Symbols of the same names, with a sparkle for work.
    case symbolsOutline

    /// The Debug Settings switch (the Debug menu writes the same value).
    public static let tunable = Tunable<StatusIconSet>.choice(
        "status.iconSet", .status, "Status icons",
        help: "The marks for agent working, blocked (permission, question, auth), done and error everywhere. Candidates for review; the default is unchanged until one is picked.",
        default: .current, code: "StatusIconSet.tunable")

    public var tunableTitle: String {
        switch self {
        case .current: String(localized: "statusIconSet.current", defaultValue: "Dots (current)", bundle: .module)
        case .shapes: String(localized: "statusIconSet.shapes", defaultValue: "Shapes", bundle: .module)
        case .rings: String(localized: "statusIconSet.rings", defaultValue: "Rings", bundle: .module)
        case .badges: String(localized: "statusIconSet.badges", defaultValue: "Badges", bundle: .module)
        case .bars: String(localized: "statusIconSet.bars", defaultValue: "Pulse Bars", bundle: .module)
        case .pips: String(localized: "statusIconSet.pips", defaultValue: "Minimal Pips", bundle: .module)
        case .signs: String(localized: "statusIconSet.signs", defaultValue: "Signs", bundle: .module)
        case .letters: String(localized: "statusIconSet.letters", defaultValue: "Letters", bundle: .module)
        case .symbols: String(localized: "statusIconSet.symbols", defaultValue: "Symbols", bundle: .module)
        case .symbolsOutline: String(localized: "statusIconSet.symbolsOutline", defaultValue: "Outlined Symbols", bundle: .module)
        }
    }

    /// One line for review sheets (not shown in the app).
    public var summary: String {
        switch self {
        case .current: "Working dots, still attention dot for every blocked kind, danger dot, check."
        case .shapes: "Sparkle, raised hand, ? bubble, key, ! for plain blocked, check, x in a ring."
        case .rings: "Outlined rings with !, ?, key inside; empty ring for plain blocked; filled disc for done."
        case .badges: "Filled discs with !, ?, key, check, x cut out; a pulsing sparkle disc for work."
        case .bars: "Three waving bars for work; bare !, ?, key, dot, check, x."
        case .pips: "Small pips: filled for permission, hollow for question, a diamond for auth."
        case .signs: "Warning triangles with !, ?, key; outlined for plain blocked; an x octagon for error."
        case .letters: "P, Q, A and ! cut out of rounded squares; check and x squares."
        case .symbols: "SF Symbols, filled: hand.raised, questionmark.bubble, key, exclamationmark.circle, checkmark.circle, xmark.octagon."
        case .symbolsOutline: "SF Symbols, outlined, and a pulsing sparkle for work."
        }
    }

    /// The set's plan for `state` before animation is applied, or nil where
    /// the set keeps the default drawing (`current`, loading, known progress).
    func plan(for state: StatusIndicatorState) -> StatusIndicatorPlan? {
        guard self != .current else { return nil }
        switch state {
        case .working where state.progress == nil:
            if self == .bars { return StatusIndicatorPlan(glyph: .bars, animation: .wave, tint: .accent) }
            if self == .signs { return StatusIndicatorPlan(glyph: .dots, animation: .wave, tint: .accent) }
            return StatusIndicatorPlan(glyph: .mark(workingMark), animation: .pulse, tint: .accent)
        case .waiting(let kind):
            if self == .bars, kind == nil { return StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .attention) }
            return StatusIndicatorPlan(glyph: .mark(blockedMark(kind)), animation: nil, tint: .attention)
        case .success:
            if self == .bars || self == .signs { return StatusIndicatorPlan(glyph: .check, animation: nil, tint: .success) }
            return StatusIndicatorPlan(glyph: .mark(doneMark), animation: nil, tint: .success)
        case .error:
            return StatusIndicatorPlan(glyph: .mark(errorMark), animation: nil, tint: .danger)
        case .idle, .busy, .paused, .working:
            return nil
        }
    }

    private var workingMark: StatusMark {
        switch self {
        case .current, .bars, .signs, .shapes: .glyph(.sparkle)
        case .rings: .outline(.circle, .dot)
        case .badges: .badge(.circle, .sparkle)
        case .pips: .glyph(.pip)
        case .letters: .outline(.roundedSquare, .dot)
        case .symbols: .symbol("ellipsis.circle.fill")
        case .symbolsOutline: .symbol("sparkle")
        }
    }

    private func blockedMark(_ kind: StatusBlockedKind?) -> StatusMark {
        switch self {
        case .current, .shapes:
            switch kind {
            case .permission?: .glyph(.hand)
            case .question?: .glyph(.bubbleQuestion)
            case .auth?: .glyph(.key)
            case nil: .glyph(.exclamation)
            }
        case .rings: .outline(.circle, Self.figure(kind))
        case .badges: .badge(.circle, Self.figure(kind) ?? .dot)
        case .bars: .glyph(Self.figure(kind) ?? .dot)
        case .pips:
            switch kind {
            case .permission?, nil: .glyph(.pip)
            case .question?: .glyph(.hollowPip)
            case .auth?: .glyph(.diamond)
            }
        case .signs: kind == nil ? .outline(.triangle, .exclamation) : .badge(.triangle, Self.figure(kind))
        case .letters:
            switch kind {
            case .permission?: .letter("P")
            case .question?: .letter("Q")
            case .auth?: .letter("A")
            case nil: .letter("!")
            }
        case .symbols:
            switch kind {
            case .permission?: .symbol("hand.raised.fill")
            case .question?: .symbol("questionmark.bubble.fill")
            case .auth?: .symbol("key.fill")
            case nil: .symbol("exclamationmark.circle.fill")
            }
        case .symbolsOutline:
            switch kind {
            case .permission?: .symbol("hand.raised")
            case .question?: .symbol("questionmark.bubble")
            case .auth?: .symbol("key")
            case nil: .symbol("exclamationmark.circle")
            }
        }
    }

    /// The small figure for a kind: ! permission, ? question, key auth.
    private static func figure(_ kind: StatusBlockedKind?) -> StatusMark.Figure? {
        switch kind {
        case .permission?: .exclamation
        case .question?: .question
        case .auth?: .key
        case nil: nil
        }
    }

    private var doneMark: StatusMark {
        switch self {
        case .current, .shapes, .bars, .signs: .glyph(.check)
        case .rings: .badge(.circle, nil)
        case .badges: .badge(.circle, .check)
        case .pips: .glyph(.pip)
        case .letters: .badge(.roundedSquare, .check)
        case .symbols: .symbol("checkmark.circle.fill")
        case .symbolsOutline: .symbol("checkmark.circle")
        }
    }

    private var errorMark: StatusMark {
        switch self {
        case .current, .shapes, .rings: .outline(.circle, .cross)
        case .badges: .badge(.circle, .cross)
        case .bars: .glyph(.cross)
        case .pips: .glyph(.pip)
        case .signs: .badge(.octagon, .cross)
        case .letters: .badge(.roundedSquare, .cross)
        case .symbols: .symbol("xmark.octagon.fill")
        case .symbolsOutline: .symbol("xmark.octagon")
        }
    }
}
