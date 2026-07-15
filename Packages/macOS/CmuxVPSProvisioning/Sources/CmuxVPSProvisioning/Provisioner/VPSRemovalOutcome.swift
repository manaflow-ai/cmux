/// Final result of `cmux vps remove` against one host.
public struct VPSRemovalOutcome: Equatable, Sendable {
    /// True when the supervised unit was stopped (live sessions terminated).
    public var stoppedUnit: Bool
    /// True when the unit file was removed.
    public var removedUnitFile: Bool
    /// True when the daemon was intentionally left running so on-host PTY
    /// sessions survive (`--keep-sessions`).
    public var keptSessions: Bool

    /// Creates an outcome.
    public init(stoppedUnit: Bool, removedUnitFile: Bool, keptSessions: Bool) {
        self.stoppedUnit = stoppedUnit
        self.removedUnitFile = removedUnitFile
        self.keptSessions = keptSessions
    }
}
