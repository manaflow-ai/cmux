public import CmuxNextDesignTokens
/// What a status indicator draws for one state, as a pure value: the layer
/// only executes the plan, so every rule here is unit tested.
public nonisolated struct StatusIndicatorPlan: Hashable, Sendable {
    public enum Glyph: Hashable, Sendable {
        case none
        /// Open arc (indeterminate).
        case arc
        /// Faint full track plus an arc of `progress`.
        case ring(progress: Double)
        /// The AppKit spinner's spokes. Determinate progress in the native
        /// style draws `ring`, which is what the AppKit determinate circular
        /// indicator is (a track and an arc).
        case native
        case dot
        case check
        /// One braille spinner frame (`BrailleSpinnerImage.frames`); `frames`
        /// steps through the rest. Still, it is the first frame.
        case braille
        /// Three small dots side by side: an agent working
        /// (WORKING-AND-LOADING-INDICATORS). No loading style draws it, so
        /// agent work never looks like a page or a command loading.
        case dots
        /// Three short bars side by side, waving like `dots` (a status icon
        /// set's working mark).
        case bars
        /// A status icon set's drawn mark (`StatusMark`, `StatusIconSet`).
        case mark(StatusMark)
    }

    public enum Animation: Hashable, Sendable {
        /// Continuous clockwise rotation (Motion `spinner` period). The only
        /// direction: every spinner turns the same way (Lawrence 2026-10-20), so
        /// there is no backward case to reach for.
        case spin
        /// Rotation in discrete steps, one spoke at a time, like the native
        /// control.
        case step
        /// Opacity breathing (Motion `pulse` period).
        case pulse
        /// The braille frames in turn, one cycle per Motion `spinner` period.
        case frames
        /// The dots dim and brighten one after another (one Motion `pulse`
        /// period per cycle).
        case wave
        /// A slow opacity breath (Motion `breath` period): agent work's dot
        /// (`StatusWorkingLook.breathe`).
        case breathe
    }

    public enum Tint: Hashable, Sendable {
        /// The configured loading color (theme secondary text by default).
        case loading
        case attention
        case danger
        case success
        /// The app's neutral accent at full strength (the theme
        /// foreground; no hue, the no-blue rule): agent work.
        case accent
        /// The theme foreground softened to Codex's spinner grey (white at
        /// 66% on Codex's dark sidebar): the Codex-like set's work.
        case spinner
        /// Codex's unread blue: the Codex-like set's done dot. The one hue a
        /// status set adds (Leo's team asked for Codex's dot, 2026-10-14).
        case unread
        /// The theme accent (`Palette.accentFill`: the text color, or the hue
        /// `appearance.accent` names): agent work's dot (`StatusWorkingLook`).
        case working
    }

    public var glyph: Glyph
    public var animation: Animation?
    public var tint: Tint

    public init(glyph: Glyph, animation: Animation?, tint: Tint) {
        self.glyph = glyph
        self.animation = animation
        self.tint = tint
    }

    public static let hidden = StatusIndicatorPlan(glyph: .none, animation: nil, tint: .loading)

    /// Agent work's spinner (the agent working-state mark): the macOS activity indicator's spokes,
    /// stepping round one spoke at a time on the shared clock. It replaced a 3/4 arc turning
    /// smoothly (Leo 2026-11-01: "who even decided to put that 3/4 circle"); loading (a page, a
    /// command) keeps its arc.
    public static func working(tint: Tint) -> StatusIndicatorPlan {
        StatusIndicatorPlan(glyph: .native, animation: .step, tint: tint)
    }

    /// The plan for `state` in `style`. `animates` is false while the host
    /// is off screen or occluded, and under Reduce Motion or loops off
    /// (`Motion.animatesLoops`): then nothing animates and the static glyph
    /// stays, so an indicator never costs a frame it cannot be seen in.
    /// `set` restyles the attention and working marks (`StatusIconSet`);
    /// the default `current` is the drawing above, unchanged. `isStatic`
    /// (`StatusIndicatorConfig.isStatic`) draws the static look whatever the
    /// set (`staticLookPlan`); `staticShapes` picks its shapes over the
    /// Static set's glyphs.
    /// `working` restyles agent work that would turn as an arc (`StatusWorkingLook`).
    public static func make(_ state: StatusIndicatorState, style: StatusIndicatorStyle, animates: Bool,
                            set: StatusIconSet = .current, isStatic: Bool = false,
                            staticShapes: Bool = false, working: StatusWorkingLook = .spinner) -> StatusIndicatorPlan {
        if isStatic { return staticLookPlan(state, style: style, shapes: staticShapes) }
        var plan = working.restyle(set.plan(for: state) ?? staticPlan(state, style: style), for: state)
        if !animates {
            plan.animation = nil
            // The Codex-like set's still work mark is a whole ring, not a stopped arc (Leo's team,
            // 2026-10-14: a static ring under Reduce Motion or the Static mode). Loading keeps its stopped arc;
            // the working dot stays a dot.
            if set == .codex, state.isWorking, state.progress == nil, plan.glyph == .native { plan.glyph = .mark(.vector(.idle)) }
        }
        return plan
    }

    static func staticPlan(_ state: StatusIndicatorState, style: StatusIndicatorStyle) -> StatusIndicatorPlan {
        switch state {
        case .idle:
            return .hidden
        case .waiting:
            // A still dot (WORKING-AND-LOADING-INDICATORS): needs input reads
            // apart from the moving working mark.
            return StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .attention)
        case .working:
            // Agent work has its own mark in every loading style (also
            // `none`): its off switch is `showAgentWorkingOnTabs` and the row's
            // working element, not the loading style.
            if let progress = state.progress {
                return StatusIndicatorPlan(glyph: .ring(progress: progress), animation: nil, tint: .accent)
            }
            return StatusIndicatorPlan(glyph: .dots, animation: .wave, tint: .accent)
        case .error:
            return StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .danger)
        case .success:
            return StatusIndicatorPlan(glyph: .check, animation: nil, tint: .success)
        case .paused:
            guard style != .none else { return .hidden }
            if let progress = state.progress {
                return StatusIndicatorPlan(glyph: .ring(progress: progress),
                                           animation: nil, tint: .attention)
            }
            return StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .attention)
        case .busy:
            if let progress = state.progress {
                guard style != .none else { return .hidden }
                return StatusIndicatorPlan(glyph: .ring(progress: progress), animation: nil, tint: .loading)
            }
            switch style {
            case .none: return .hidden
            case .arc: return StatusIndicatorPlan(glyph: .arc, animation: .spin, tint: .loading)
            case .native: return StatusIndicatorPlan(glyph: .native, animation: .step, tint: .loading)
            case .dot: return StatusIndicatorPlan(glyph: .dot, animation: .pulse, tint: .loading)
            case .braille: return StatusIndicatorPlan(glyph: .braille, animation: .frames, tint: .loading)
            }
        }
    }
}
