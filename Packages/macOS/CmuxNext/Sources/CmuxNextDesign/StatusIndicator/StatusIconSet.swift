public import Foundation
public import CmuxNextDesignTokens

/// Status icon candidate sets (cx-kxa2, Lawrence 2026-10-08: "make sure we
/// have better notif icons for osc 7501 things ... make sure i can try a
/// bunch of different icons so we can search for the best one together").
/// A DEV and NIGHTLY switch in Debug Settings (section "Status Indicators")
/// and in the Debug menu ("Status Icons"); it restyles every indicator
/// (sidebar rows, group headers, tab icon slots and badges) live. Each set
/// marks working, blocked (with the OSC 7501 kind: permission, question,
/// auth), done and error; idle draws nothing. Loading (busy, paused) and
/// known progress keep the loading style's marks. Colors are theme roles
/// only. The default is `codex` (Leo 2026-10-14, a team decision; was
/// `symbols`, Lawrence 2026-10-09); `current` keeps the original drawing.
public nonisolated enum StatusIconSet: String, Sendable, CaseIterable, TunableChoice {
    /// Today's marks: working dots, a still attention dot, a danger dot, a check.
    case current
    /// Pictures: a raised hand, a speech bubble with ?, a key, a check, x in a circle.
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
    /// Outlined SF Symbols of the same names.
    case symbolsOutline
    /// The static glyphs (`StaticStatusGlyph`, Leo 2026-10-14): one still shape per state, drawn for
    /// the Static status mode (Reduce Motion): a half-filled ring for work, an attention dot for a wait (no talk bubble), a shield,
    /// a check disc, a ! diamond.
    case still
    /// Codex-like (Leo's team, 2026-10-14: "they like Codex's sidebar"): work spins in a neutral grey
    /// (the shared spinner, re-tinted; a still ring when nothing may move), done is Codex's blue
    /// dot, a wait is an attention dot (no talk bubble, Lawrence 2026-10-20) and permission a muted line
    /// shield, and only an error is red (a line i in a ring).
    case codex
    /// The quiet static glyphs (`sets.dots` in static-status.json, hq#1957 status glyph thunderdome):
    /// one small dot, hollow (half-filled working, a ringed dot waiting) or solid with a bar, check or
    /// x cut out (permission, done, error). Debug only; never the default.
    case stillDots
    /// The bold static glyphs (`sets.pictograms`, hq#1957 status glyph thunderdome): an hourglass, a
    /// chat bubble with dots, a padlock, a check, a warning triangle. Debug only; never the default.
    case stillPictograms

    /// The Debug Settings switch (the Debug menu writes the same value).
    public static let tunable = Tunable<StatusIconSet>.choice(
        "status.iconSet", .status, "Status icons",
        help: "The marks for agent working, blocked (permission, question, auth), done and error everywhere. Codex-like is the default; Dots is the original drawing.",
        default: .codex, code: "StatusIconSet.tunable")

    public var tunableTitle: String {
        switch self {
        case .current: String(localized: "statusIconSet.current", defaultValue: "Dots (original)", bundle: .module)
        case .shapes: String(localized: "statusIconSet.shapes", defaultValue: "Shapes", bundle: .module)
        case .rings: String(localized: "statusIconSet.rings", defaultValue: "Rings", bundle: .module)
        case .badges: String(localized: "statusIconSet.badges", defaultValue: "Badges", bundle: .module)
        case .bars: String(localized: "statusIconSet.bars", defaultValue: "Pulse Bars", bundle: .module)
        case .pips: String(localized: "statusIconSet.pips", defaultValue: "Minimal Pips", bundle: .module)
        case .signs: String(localized: "statusIconSet.signs", defaultValue: "Signs", bundle: .module)
        case .letters: String(localized: "statusIconSet.letters", defaultValue: "Letters", bundle: .module)
        case .symbols: String(localized: "statusIconSet.symbols", defaultValue: "Symbols", bundle: .module)
        case .symbolsOutline: String(localized: "statusIconSet.symbolsOutline", defaultValue: "Outlined Symbols", bundle: .module)
        case .still: String(localized: "statusIconSet.still", defaultValue: "Static", bundle: .module)
        case .codex: String(localized: "statusIconSet.codex", defaultValue: "Codex-like", bundle: .module)
        case .stillDots: String(localized: "statusIconSet.stillDots", defaultValue: "Static Dots", bundle: .module)
        case .stillPictograms: String(localized: "statusIconSet.stillPictograms", defaultValue: "Static Pictograms", bundle: .module)
        }
    }

    /// One line for review sheets (not shown in the app).
    public var summary: String {
        switch self {
        case .current: "Working dots, still attention dot for every blocked kind, danger dot, check."
        case .shapes: "Raised hand, ? bubble, key, ! for plain blocked, check, x in a ring; a spinner for work."
        case .rings: "Outlined rings with !, ?, key inside; empty ring for plain blocked; filled disc for done."
        case .badges: "Filled discs with !, ?, key, check, x cut out; a spinner for work."
        case .bars: "Three waving bars for work; bare !, ?, key, dot, check, x."
        case .pips: "Small pips: filled for permission, hollow for question, a diamond for auth; a spinner for work."
        case .signs: "Warning triangles with !, ?, key; outlined for plain blocked; an x octagon for error."
        case .letters: "P, Q, A and ! cut out of rounded squares; check and x squares."
        case .symbols: "SF Symbols, filled: hand.raised, questionmark.bubble, key, exclamationmark.circle, checkmark.circle, xmark.octagon; a spinner for work."
        case .symbolsOutline: "SF Symbols, outlined, and a spinner for work."
        case .still: "Static glyphs, never animated: half-filled ring, attention dot, shield, check disc, ! diamond."
        case .codex: "Codex's sidebar: a grey spinner (a still ring under Reduce Motion), blue done dot, attention dot for a wait, muted line shield for permission, red line i."
        case .stillDots: "Static dots, never animated: half-filled dot, ringed dot, dot with a bar, check or x cut out."
        case .stillPictograms: "Static pictograms, never animated: hourglass, chat bubble, padlock, check, warning triangle."
        }
    }

    /// The set's plan for `state` before animation is applied, or nil where
    /// the set keeps the default drawing (`current`, loading, known progress).
    func plan(for state: StatusIndicatorState) -> StatusIndicatorPlan? {
        guard self != .current else { return nil }
        // Idle draws nothing in every set; the idle glyph is for hosts that show a still idle mark.
        // Known progress keeps its ring, which never moves and says how far along the work is.
        if isStatic {
            if state == .idle || (state.isWorking && state.progress != nil) { return nil }
            return staticGlyph(for: state)?.plan
        }
        if self == .codex { return codexPlan(for: state) }
        switch state {
        case .working where state.progress == nil:
            if self == .bars { return StatusIndicatorPlan(glyph: .bars, animation: .wave, tint: .accent) }
            if self == .signs { return StatusIndicatorPlan(glyph: .dots, animation: .wave, tint: .accent) }
            // A spinner in the muted loading color, not a pulsing mark (Lawrence 2026-10-14: "left
            // sidebar needs to be a spinner instead of flash", cx-qtgj2): the working spinner
            // (`StatusIndicatorPlan.working`). Still under Reduce Motion, occlusion or loops off
            // (`StatusIndicatorPlan.make`).
            return StatusIndicatorPlan.working(tint: .loading)
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
        case .still, .stillDots, .stillPictograms:
            .vector(staticGlyph(for: .waiting(kind: kind)) ?? .waiting)
        case .codex: .vector(kind == .permission || kind == .auth ? .shieldLine : .dot)
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
        case .still, .stillDots, .stillPictograms: .vector(staticGlyph(for: .success) ?? .done)
        case .codex: .vector(.dot)
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
        case .still, .stillDots, .stillPictograms: .vector(staticGlyph(for: .error) ?? .error)
        case .codex: .vector(.info)
        }
    }

    /// Whether the set draws only the static glyphs (`still`, `stillDots`, `stillPictograms`).
    var isStatic: Bool { self == .still || self == .stillDots || self == .stillPictograms }

    /// The static glyph a static set draws for `state` (`sets` in static-status.json names the Dots
    /// and Pictograms picks; each keeps the Static set's theme role per state), nil for loading and
    /// for the other sets.
    func staticGlyph(for state: StatusIndicatorState) -> StaticStatusGlyph? {
        guard let glyph = StaticStatusGlyph(state) else { return nil }
        switch self {
        case .still: return glyph
        case .stillDots: return glyph.dots
        case .stillPictograms: return glyph.pictograms
        case .current, .shapes, .rings, .badges, .bars, .pips, .signs, .letters, .symbols, .symbolsOutline, .codex:
            return nil
        }
    }

    /// The Codex-like set (`sets.codex` in schemas/status-glyphs/static-status.json, which the web
    /// copy follows): the working spinner re-tinted grey for work, line glyphs for the rest.
    private func codexPlan(for state: StatusIndicatorState) -> StatusIndicatorPlan? {
        switch state {
        case .working where state.progress == nil:
            return StatusIndicatorPlan.working(tint: .spinner)
        case .waiting(let kind) where kind == .permission || kind == .auth:
            return StatusIndicatorPlan(glyph: .mark(blockedMark(kind)), animation: nil, tint: .loading)
        case .waiting:
            // No talk bubble (Lawrence 2026-10-20: "rm the talk icon"): waiting on you is the set's
            // one dot, in the attention tint so it reads apart from done's blue dot.
            return StatusIndicatorPlan(glyph: .mark(.vector(.dot)), animation: nil, tint: .attention)
        case .success:
            return StatusIndicatorPlan(glyph: .mark(doneMark), animation: nil, tint: .unread)
        case .error:
            return StatusIndicatorPlan(glyph: .mark(errorMark), animation: nil, tint: .danger)
        case .idle, .busy, .paused, .working:
            return nil
        }
    }
}
