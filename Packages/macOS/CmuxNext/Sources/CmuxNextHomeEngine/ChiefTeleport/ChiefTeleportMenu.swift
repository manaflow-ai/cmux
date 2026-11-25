/// The Teleport menu's contents (the Home header's location chip and the Chief card's row), pure:
/// every destination in the list's order, the one the Chief runs at checked and not pickable, the
/// ones that cannot take it greyed out, every row locked while a move runs, and Roll Back only while
/// the home is marked moved.
public nonisolated struct ChiefTeleportMenu: Equatable, Sendable {
    /// One destination row.
    public struct Row: Equatable, Sendable {
        /// What a click on the row can do.
        public enum State: Equatable, Sendable {
            /// A click moves the Chief there.
            case available
            /// The Chief runs there now (checked, no click).
            case current
            /// The destination cannot take the Chief now (its title says why).
            case unavailable
            /// Another move or a rollback runs.
            case busy
        }

        /// The `chief.moveTo` target.
        public var id: String
        public var title: String
        public var state: State
    }

    /// The Roll Back row.
    public enum Rollback: Equatable, Sendable {
        /// A click runs `cmux chief move rollback`.
        case available
        /// A move or rollback runs.
        case busy
    }

    public let rows: [Row]
    /// Nil when the home is not marked moved (nothing to roll back).
    public let rollback: Rollback?
    /// Where the Chief runs, as the menu names it: the matching row's title (a host's group name),
    /// else the host name; nil for This Mac or cmux Cloud with no pickable row naming them (the
    /// chip's own words).
    public let currentTitle: String?

    /// - Parameters:
    ///   - location: Where the Chief runs (``ChiefLocationReader``).
    ///   - destinations: The app's move targets, in order.
    ///   - phase: The running or last move.
    public init(location: ChiefLocation, destinations: [ChiefTeleportDestination], phase: ChiefTeleportPhase) {
        let running = phase.isRunning
        rows = destinations.map { destination in
            let state: Row.State = if destination.holds(location) {
                .current
            } else if running {
                .busy
            } else {
                destination.isAvailable ? .available : .unavailable
            }
            return Row(id: destination.id, title: destination.title, state: state)
        }
        rollback = location == .thisMac ? nil : (running ? .busy : .available)
        let held = destinations.first { $0.holds(location) }
        switch location {
        case .host(let host): currentTitle = held?.title ?? host
        // A greyed-out row's title carries its reason ("cmux Cloud (sign in first)"): the chip's own words then.
        case .thisMac, .cloud: currentTitle = held.flatMap { $0.isAvailable ? $0.title : nil }
        }
    }
}
