/// The peek machine's full state: which phase it is in and what is holding it
/// open.
public struct SidebarPeekState: Sendable, Hashable {
    /// The current phase.
    public private(set) var phase: SidebarPeekPhase
    /// Reasons the panel must stay open regardless of pointer position.
    public private(set) var holds: SidebarPeekHold

    /// Whether the floating panel should be on screen.
    public var presentsPanel: Bool {
        phase.presentsPanel
    }

    /// The idle starting state.
    public static let idle = SidebarPeekState(phase: .idle, holds: [])

    /// Creates a state.
    ///
    /// - Parameters:
    ///   - phase: The phase to start in.
    ///   - holds: Holds already in effect.
    public init(phase: SidebarPeekPhase, holds: SidebarPeekHold) {
        self.phase = phase
        self.holds = holds
    }

    /// Replaces the phase.
    mutating func setPhase(_ phase: SidebarPeekPhase) {
        self.phase = phase
    }

    /// Adds a hold.
    mutating func insert(_ hold: SidebarPeekHold) {
        holds.insert(hold)
    }

    /// Removes a hold.
    mutating func remove(_ hold: SidebarPeekHold) {
        holds.remove(hold)
    }

    /// Clears every hold, used when peek shuts down entirely.
    mutating func clearHolds() {
        holds = []
    }
}
