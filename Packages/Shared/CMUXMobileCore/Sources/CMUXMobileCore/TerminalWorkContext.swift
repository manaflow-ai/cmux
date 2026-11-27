/// An immutable, content-free snapshot of the geometry operation's owner.
public struct TerminalWorkContext: Sendable, Codable, Equatable {
    /// The user or lifecycle transition that requested the work.
    public enum Transition: String, Sendable, Codable, CaseIterable {
        /// The caller cannot establish the originating transition.
        case unknown
        /// A pane is being split.
        case split
        /// A saved workspace is being restored.
        case restore
        /// An existing terminal is becoming visible.
        case reveal
        /// Terminal bounds or the negotiated grid are changing.
        case resize
    }

    /// The population described by the counts, independent of user identity.
    public enum Population: String, Sendable, Codable {
        /// The originating workspace and the surfaces it currently owns.
        case workspace
        /// All workspaces and surfaces in the owning Mac window.
        case window
        /// The terminal surfaces bound to one window portal.
        case portal
        /// The workspaces and surfaces known for the selected mobile host.
        case mobileHost
        /// No population snapshot was supplied.
        case unknown
    }

    /// The known originating transition; unknown is never inferred as resize.
    public let transition: Transition
    /// The scope of the counts.
    public let population: Population
    /// Workspace count, or nil when unavailable.
    public let workspaceCount: Int?
    /// Surface count, or nil when unavailable.
    public let surfaceCount: Int?

    /// Creates bounded counters without retaining any model identifiers.
    /// - Parameters:
    ///   - transition: The known operation trigger.
    ///   - population: The scope counted by the owner.
    ///   - workspaceCount: Workspace count, clamped to the UInt16 range.
    ///   - surfaceCount: Surface count, clamped to the UInt16 range.
    public init(
        transition: Transition = .unknown,
        population: Population = .unknown,
        workspaceCount: Int? = nil,
        surfaceCount: Int? = nil
    ) {
        self.transition = transition
        self.population = population
        self.workspaceCount = workspaceCount.map { min(max(0, $0), Int(UInt16.max)) }
        self.surfaceCount = surfaceCount.map { min(max(0, $0), Int(UInt16.max)) }
    }
}
