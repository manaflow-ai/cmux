/// The static look (`appearance.statusIndicator.animation: "static"`, or
/// Reduce Motion; cx-sya4n, Leo 2026-10-13: "What if they were just colors or
/// symbols or some text"). Nothing moves, and every state draws its own
/// shape, so no two read apart by color alone. Independent of the Debug icon
/// set; the marks are the existing `StatusMark` art.
nonisolated extension StatusIndicatorPlan {
    /// The still plan for `state`: never animated.
    static func stillPlan(_ state: StatusIndicatorState, style: StatusIndicatorStyle) -> StatusIndicatorPlan {
        switch state {
        case .idle:
            return .hidden
        case .working:
            // A solid dot: work under way, apart from loading's open arc.
            return StatusIndicatorPlan(glyph: state.progress.map { Glyph.ring(progress: $0) } ?? .dot, animation: nil, tint: .accent)
        case .waiting(let kind):
            let figure: StatusMark.Figure = switch kind {
            case .permission?: .hand
            case .question?: .bubbleQuestion
            case .auth?: .key
            case nil: .exclamation
            }
            return StatusIndicatorPlan(glyph: .mark(.glyph(figure)), animation: nil, tint: .attention)
        case .error:
            return StatusIndicatorPlan(glyph: .mark(.outline(.circle, .cross)), animation: nil, tint: .danger)
        case .success:
            return StatusIndicatorPlan(glyph: .check, animation: nil, tint: .success)
        case .paused:
            guard style != .none else { return .hidden }
            // An empty ring: stopped part way.
            return StatusIndicatorPlan(glyph: state.progress.map { Glyph.ring(progress: $0) } ?? .mark(.outline(.circle, nil)),
                                       animation: nil, tint: .attention)
        case .busy:
            if let progress = state.progress {
                guard style != .none else { return .hidden }
                return StatusIndicatorPlan(glyph: .ring(progress: progress), animation: nil, tint: .loading)
            }
            switch style {
            case .none: return .hidden
            // The still dot is working's mark: loading keeps an open arc.
            case .arc, .dot: return StatusIndicatorPlan(glyph: .arc, animation: nil, tint: .loading)
            case .native: return StatusIndicatorPlan(glyph: .native, animation: nil, tint: .loading)
            case .braille: return StatusIndicatorPlan(glyph: .braille, animation: nil, tint: .loading)
            }
        }
    }
}
