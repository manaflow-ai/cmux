public import CmuxTheme

/// What the window backdrop shows of the agents (`appearance.agentGlow`, off by default): nothing
/// while every agent is idle, a faint wash in its machine's color while one works, a soft glow at
/// the window's edges while one waits on the person (ask: "all of them" / "some of them maybe just
/// as customizations lol if it affects default looks", Leo, 2026-11-19).
///
/// The glow is drawn once per change and then holds (``WindowMaterialView``): no frame clock runs
/// for it, so a calm window costs nothing and a glowing one costs one composited layer.
///
/// ```swift
/// let glow = BackdropAgentGlow(agents: [.init(machine: "my-vm", state: .waiting)]) { MachineColor(name: $0).rgb(...) }
/// ```
public nonisolated struct BackdropAgentGlow: Hashable, Sendable {
    /// How loud the backdrop is, in the order one agent's state outranks another's.
    public enum Level: Int, Comparable, Sendable {
        /// Every agent idle, or none: the backdrop as the person set it.
        case calm
        /// An agent works: a faint wash.
        case working
        /// An agent waits on the person (a chat's permission or question, a blocked terminal agent): the glow.
        case needsYou

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One agent as the glow reads it: its machine's name and its state.
    public struct Agent: Hashable, Sendable {
        public var machine: String
        public var level: Level

        public init(machine: String, level: Level) {
            self.machine = machine
            self.level = level
        }
    }

    /// The level shown.
    public var level: Level
    /// The color of the machine whose agent set ``level``; nil while calm.
    public var color: ThemeRGB?

    /// No glow: what the backdrop shows with the setting off.
    public static let calm = BackdropAgentGlow(level: .calm, color: nil)

    public init(level: Level, color: ThemeRGB?) {
        self.level = level
        self.color = level == .calm ? nil : color
    }

    /// The glow `agents` call for: the loudest state wins, and among agents at that state the
    /// machine named first in sorted order, so the hue holds still while the same agents wait.
    /// `color` maps a machine's name to its identity color (``MachineColor``).
    public init(agents: [Agent], color: (String) -> ThemeRGB) {
        guard let loudest = agents.map(\.level).max(), loudest > .calm,
              let machine = agents.filter({ $0.level == loudest }).map(\.machine).min() else {
            self = .calm
            return
        }
        self.init(level: loudest, color: color(machine))
    }

    /// The alpha of ``color`` at the window's edges at full strength; the center stays clear.
    public static let edgeAlpha = 0.32

    /// The glow layer's opacity once its fade ends: 0 while calm (the layer is hidden).
    public var opacity: Float {
        switch level {
        case .calm: 0
        case .working: 0.35
        case .needsYou: 1
        }
    }
}
