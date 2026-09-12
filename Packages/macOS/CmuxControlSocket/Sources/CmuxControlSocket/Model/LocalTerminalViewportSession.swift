public import Foundation

/// Main-actor owner for viewport overrides belonging to one socket connection.
///
/// A session is created when an accepted local socket starts handling commands
/// and released when that handler disconnects. Keeping the map here makes the
/// lifecycle invariant explicit: a surface can have different projections for
/// different connections, and no override can outlive its connection.
@MainActor
public final class LocalTerminalViewportSession {
    /// The accepted socket connection that owns this session.
    public let connectionID: UUID

    private var overridesBySurfaceID: [UUID: LocalTerminalViewport] = [:]

    /// Creates an empty session for one socket connection.
    /// - Parameter connectionID: Stable identity of the accepted connection.
    public init(connectionID: UUID) {
        self.connectionID = connectionID
    }

    /// Returns the override currently assigned to `surfaceID`, if any.
    public func viewport(for surfaceID: UUID) -> LocalTerminalViewport? {
        overridesBySurfaceID[surfaceID]
    }

    /// Installs or replaces one surface override.
    /// - Parameters:
    ///   - viewport: Validated cell dimensions to project.
    ///   - surfaceID: Surface whose frames and text reads should be projected.
    public func set(_ viewport: LocalTerminalViewport, for surfaceID: UUID) {
        overridesBySurfaceID[surfaceID] = viewport
    }

    /// Removes one surface override.
    /// - Parameter surfaceID: Surface to restore to its native projection.
    /// - Returns: `true` when an override was removed.
    @discardableResult
    public func reset(surfaceID: UUID) -> Bool {
        overridesBySurfaceID.removeValue(forKey: surfaceID) != nil
    }

    /// Drops every override. Callers may use this explicitly during teardown;
    /// normal disconnect also releases the session object itself.
    public func clear() {
        overridesBySurfaceID.removeAll(keepingCapacity: false)
    }

    /// Whether the session owns at least one override.
    public var isEmpty: Bool {
        overridesBySurfaceID.isEmpty
    }

    deinit {
        // The handler owns the session for exactly one accepted socket
        // lifetime. Clear the map at destruction so a disconnect cannot leave
        // a surface override reachable through a retained reference.
        overridesBySurfaceID.removeAll(keepingCapacity: false)
    }
}
