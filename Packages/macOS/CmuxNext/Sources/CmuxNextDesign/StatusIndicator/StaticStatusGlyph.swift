public import CmuxNextDesignTokens
/// Which static glyph a status shows (the Static status mode, Leo 2026-10-14).
nonisolated extension StaticStatusGlyph {
    /// The glyph for `state`: nil for loading (busy, paused), which keeps its loading style, still
    /// when nothing animates. A working agent is `working` (the Static set keeps a known-progress ring, which never moves); a
    /// permission or sign-in request is `permission`, any other wait `waiting`.
    public init?(_ state: StatusIndicatorState) {
        switch state {
        case .idle: self = .idle
        case .working: self = .working
        case .waiting(let kind): self = kind == .permission || kind == .auth ? .permission : .waiting
        case .success: self = .done
        case .error: self = .error
        case .busy, .paused: return nil
        }
    }

    /// The indicator plan that draws this glyph: no animation, its theme role.
    public var plan: StatusIndicatorPlan { StatusIndicatorPlan(glyph: .mark(.vector(self)), animation: nil, tint: tint) }
}

/// The Dots and Pictograms sets' glyphs (hq#1957 status glyph thunderdome; `sets.dots` and
/// `sets.pictograms` in schemas/status-glyphs/static-status.json): the same states as the Static
/// set, drawn as other shapes in the same theme roles.
nonisolated extension StaticStatusGlyph {
    /// The Dots set's glyph for this Static state; another set's glyph stays itself.
    public var dots: StaticStatusGlyph {
        switch self {
        case .idle: .dotsIdle
        case .working: .dotsWorking
        case .waiting: .dotsWaiting
        case .permission: .dotsPermission
        case .done: .dotsDone
        case .error: .dotsError
        default: self
        }
    }

    /// The Pictograms set's glyph for this Static state; another set's glyph stays itself.
    public var pictograms: StaticStatusGlyph {
        switch self {
        case .idle: .pictogramsIdle
        case .working: .pictogramsWorking
        case .waiting: .pictogramsWaiting
        case .permission: .pictogramsPermission
        case .done: .pictogramsDone
        case .error: .pictogramsError
        default: self
        }
    }
}
