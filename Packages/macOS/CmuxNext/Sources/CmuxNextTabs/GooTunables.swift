import CCmuxMotionFFI
public import CmuxNextDesign
public import CmuxNextDesignTokens

/// One goo spring: response (seconds for one undamped oscillation) and damping fraction (1 is critically damped,
/// under 1 passes its target). Mirrors `CmuxGooSpring` (plans/cmux-next/gooey-tabs.md, "The C ABI").
public nonisolated struct GooSpring: Sendable, Equatable {
    public var response: Double
    public var dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }
}

/// A level's goo tuning, field for field `CmuxGooTuning` (plans/cmux-next/gooey-tabs.md): one spring per event, and
/// the goo's geometry. `stretch` and `lean` are fractions, `feetScale` scales the fillets' radius, `k` (the smooth
/// union's threshold), `breakDistance`, `captureDistance` and `wobbleAmplitude` are points.
public nonisolated struct GooTuning: Sendable, Equatable {
    public var select, open, close, reorder, snap, absorb, wobble: GooSpring
    public var stretch, lean, feetScale, k, breakDistance, captureDistance, wobbleAmplitude: Double

    public init(select: GooSpring, open: GooSpring, close: GooSpring, reorder: GooSpring, snap: GooSpring,
                absorb: GooSpring, wobble: GooSpring, stretch: Double, lean: Double, feetScale: Double, k: Double,
                breakDistance: Double, captureDistance: Double, wobbleAmplitude: Double) {
        self.select = select
        self.open = open
        self.close = close
        self.reorder = reorder
        self.snap = snap
        self.absorb = absorb
        self.wobble = wobble
        self.stretch = stretch
        self.lean = lean
        self.feetScale = feetScale
        self.k = k
        self.breakDistance = breakDistance
        self.captureDistance = captureDistance
        self.wobbleAmplitude = wobbleAmplitude
    }

    /// The default tuning of `level`: Rust's `GooTuning::for_level` (cmux-motion), read once per level over the
    /// C ABI, so the levels' springs and geometry live in one place (plans/cmux-next/gooey-tabs.md, "Levels").
    public static func defaults(for level: GooeyTabs) -> GooTuning {
        switch level {
        case .off: off
        case .subtle: subtle
        case .full: full
        }
    }

    /// Off: critically damped, no stretch, lean, neck or wobble (the strip keeps its motion tokens).
    public static let off = GooTuning(cmux_goo_tuning_for_level(CmuxGooLevelOff))
    public static let subtle = GooTuning(cmux_goo_tuning_for_level(CmuxGooLevelSubtle))
    public static let full = GooTuning(cmux_goo_tuning_for_level(CmuxGooLevelFull))
}

/// The gooey tabs' knobs (plans/cmux-next/gooey-tabs.md, "Knobs"): every goo spring and goo parameter of each level as
/// a Debug Settings tunable, one section per level ("Gooey tabs: Subtle", "Gooey tabs: Full"), defaulting to
/// ``GooTuning/defaults(for:)`` and read live (``tuning(for:)``). A spring is two numbers, not a `.spring` tunable:
/// the spring kind clamps damping to 1 and up (the motion tokens' rule, Lawrence 2026-11-10), and the goo springs are
/// this variant's own tuning, under 1 by design. Off has no knobs: it keeps the strip's tokens.
public nonisolated struct GooTunables {
    public nonisolated init() {}
    public static let subtleSection = TunableSection(id: "gooSubtle", title: "Gooey tabs: Subtle", symbol: "drop.halffull", order: 16)
    public static let fullSection = TunableSection(id: "gooFull", title: "Gooey tabs: Full", symbol: "drop.fill", order: 17)

    /// The events with a spring of their own, in `CmuxGooTuning`'s order.
    public nonisolated enum Event: String, Sendable, CaseIterable {
        case select, open, close, reorder, snap, absorb, wobble

        var keyPath: WritableKeyPath<GooTuning, GooSpring> {
            switch self {
            case .select: \.select
            case .open: \.open
            case .close: \.close
            case .reorder: \.reorder
            case .snap: \.snap
            case .absorb: \.absorb
            case .wobble: \.wobble
            }
        }
    }

    /// A goo parameter, its key's last part, label, help and control.
    public nonisolated enum Parameter: String, Sendable, CaseIterable {
        case stretch, lean
        case feetScale = "feet_scale"
        case k
        case breakDistance = "break_distance"
        case captureDistance = "capture_distance"
        case wobbleAmplitude = "wobble_amplitude"

        var keyPath: WritableKeyPath<GooTuning, Double> {
            switch self {
            case .stretch: \.stretch
            case .lean: \.lean
            case .feetScale: \.feetScale
            case .k: \.k
            case .breakDistance: \.breakDistance
            case .captureDistance: \.captureDistance
            case .wobbleAmplitude: \.wobbleAmplitude
            }
        }

        var label: String {
            switch self {
            case .stretch: "Stretch on select"
            case .lean: "Lean"
            case .feetScale: "Fillet radius scale"
            case .k: "Goo threshold (k)"
            case .breakDistance: "Neck break distance"
            case .captureDistance: "Neck capture distance"
            case .wobbleAmplitude: "Settle wobble"
            }
        }

        var help: String {
            switch self {
            case .stretch: "How far the selection blob stretches toward its travel on a move, as a share of its width."
            case .lean: "How far the blob's top corners skew toward the travel, as a share of its height."
            case .feetScale: "The fillets' radius where the selected tab meets the card, as a multiple of the flush-goo radius."
            case .k: "The smooth union's threshold: how near a neighbour or a dragged tab merges into the blob."
            case .breakDistance: "How far a dragged tab pulls from its slot before the neck snaps off."
            case .captureDistance: "How near a dragged tab comes back before the slot absorbs it (under the break distance, so it does not flicker)."
            case .wobbleAmplitude: "The settle wobble's amplitude when the blob comes to rest."
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .stretch, .lean: 0...1
            case .feetScale: 0...3
            case .k: 0...32
            case .breakDistance, .captureDistance: 0...160
            case .wobbleAmplitude: 0...12
            }
        }

        var step: Double {
            switch self {
            case .stretch, .lean, .feetScale: 0.01
            case .k, .breakDistance, .captureDistance, .wobbleAmplitude: 0.5
            }
        }

        var unit: TunableUnit {
            switch self {
            case .stretch, .lean: .fraction
            case .feetScale: .multiplier
            case .k, .breakDistance, .captureDistance, .wobbleAmplitude: .points
            }
        }
    }

    /// One level's knobs.
    public nonisolated struct Level: Sendable {
        public let level: GooeyTabs
        public let responses: [Event: Tunable<Double>]
        public let dampings: [Event: Tunable<Double>]
        public let parameters: [Parameter: Tunable<Double>]

        init(_ level: GooeyTabs, _ section: TunableSection, _ title: String) {
            self.level = level
            let defaults = GooTuning.defaults(for: level)
            let prefix = "goo.\(level.rawValue)"
            var responses: [Event: Tunable<Double>] = [:], dampings: [Event: Tunable<Double>] = [:]
            for event in Event.allCases {
                let spring = defaults[keyPath: event.keyPath]
                responses[event] = .number(
                    "\(prefix).\(event.rawValue).response", section, "\(title): \(event.rawValue) response",
                    help: "Seconds for one undamped oscillation of the \(event.rawValue) spring; smaller is stiffer.",
                    default: spring.response, range: 0.02...2, step: 0.01, unit: .seconds,
                    code: "GooTuning.\(level.rawValue).\(event.rawValue).response")
                dampings[event] = .number(
                    "\(prefix).\(event.rawValue).damping", section, "\(title): \(event.rawValue) damping",
                    help: "Damping fraction of the \(event.rawValue) spring: 1 is critically damped, under 1 overshoots and wobbles.",
                    default: spring.dampingFraction, range: 0.1...1.5, step: 0.01, unit: .multiplier,
                    code: "GooTuning.\(level.rawValue).\(event.rawValue).dampingFraction")
            }
            var parameters: [Parameter: Tunable<Double>] = [:]
            for parameter in Parameter.allCases {
                parameters[parameter] = .number(
                    "\(prefix).\(parameter.rawValue)", section, "\(title): \(parameter.label)", help: parameter.help,
                    default: defaults[keyPath: parameter.keyPath], range: parameter.range, step: parameter.step,
                    unit: parameter.unit, code: "GooTuning.\(level.rawValue).\(parameter)")
            }
            self.responses = responses
            self.dampings = dampings
            self.parameters = parameters
        }

        /// The tuning in effect: each knob's override, else its default.
        public var tuning: GooTuning {
            var tuning = GooTuning.defaults(for: level)
            for event in Event.allCases {
                tuning[keyPath: event.keyPath] = GooSpring(response: responses[event]?.value ?? tuning[keyPath: event.keyPath].response,
                                                           dampingFraction: dampings[event]?.value ?? tuning[keyPath: event.keyPath].dampingFraction)
            }
            for parameter in Parameter.allCases {
                if let knob = parameters[parameter] { tuning[keyPath: parameter.keyPath] = knob.value }
            }
            return tuning
        }

        /// Every knob, springs first (in event order), then the parameters.
        public var descriptors: [TunableDescriptor] {
            Event.allCases.flatMap { [responses[$0], dampings[$0]].compactMap { $0?.descriptor } }
                + Parameter.allCases.compactMap { parameters[$0]?.descriptor }
        }
    }

    public static let subtle = Level(.subtle, subtleSection, "Subtle")
    public static let full = Level(.full, fullSection, "Full")

    /// The tuning `level` runs with, Debug Settings overrides applied live; off is ``GooTuning/off``.
    public static func tuning(for level: GooeyTabs) -> GooTuning {
        switch level {
        case .off: GooTuning.off
        case .subtle: subtle.tuning
        case .full: full.tuning
        }
    }

    public static var all: [TunableDescriptor] { subtle.descriptors + full.descriptors }
}
