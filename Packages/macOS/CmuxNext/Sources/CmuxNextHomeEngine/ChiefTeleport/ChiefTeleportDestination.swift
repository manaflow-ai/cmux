/// One place the Teleport menu offers (the app's "Move Chief To…" target, `ChiefMoveTargets`): its
/// id for `chief.moveTo`, its title as the menu shows it, and where it is, so the menu can check
/// the one the Chief runs at now.
public nonisolated struct ChiefTeleportDestination: Equatable, Sendable {
    /// Where a destination is.
    public enum Place: Equatable, Sendable {
        /// The Chief's home on this Mac.
        case thisMac
        /// The account's hosted Chief.
        case cloud
        /// Another machine, by the SSH destination the move takes (`user@host` or `host`).
        case host(String)
    }

    /// The `chief.moveTo` `target` (the target's machine id).
    public var id: String
    /// The menu row's text; a greyed-out row says why ("gcp-linux-1 (offline)").
    public var title: String
    public var place: Place
    /// False when the target cannot take the Chief now (offline, no SSH route, signed out).
    public var isAvailable: Bool

    /// - Parameters:
    ///   - id: The `chief.moveTo` target.
    ///   - title: The row's text, with the reason when it is not available.
    ///   - place: Where it is.
    ///   - isAvailable: Whether it can take the Chief now (default true).
    public init(id: String, title: String, place: Place, isAvailable: Bool = true) {
        self.id = id
        self.title = title
        self.place = place
        self.isAvailable = isAvailable
    }

    /// Whether the Chief at `location` runs here.
    func holds(_ location: ChiefLocation) -> Bool {
        switch (place, location) {
        case (.thisMac, .thisMac), (.cloud, .cloud): true
        case (.host(let destination), .host(let host)): ChiefLocation.hostName(destination) == host
        default: false
        }
    }
}
