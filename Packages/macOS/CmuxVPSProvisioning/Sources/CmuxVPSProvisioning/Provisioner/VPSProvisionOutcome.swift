/// Final result of `cmux vps add` / `cmux vps upgrade` against one host.
public struct VPSProvisionOutcome: Equatable, Sendable {
    /// Version now installed and (on systemd hosts) supervised.
    public var installedVersion: String
    /// Remote GOOS.
    public var goOS: String
    /// Remote GOARCH.
    public var goArch: String
    /// Distro `ID` from the probe (may be empty).
    public var distroID: String
    /// Unit scope installed, or `nil` on non-systemd hosts.
    public var unitScope: VPSUnitScope?
    /// True when the host was already fully converged (pure no-op re-run).
    public var alreadyConverged: Bool
    /// Post-provision health from real daemon signals.
    public var health: VPSHostHealth

    /// Creates an outcome.
    public init(
        installedVersion: String,
        goOS: String,
        goArch: String,
        distroID: String,
        unitScope: VPSUnitScope?,
        alreadyConverged: Bool,
        health: VPSHostHealth
    ) {
        self.installedVersion = installedVersion
        self.goOS = goOS
        self.goArch = goArch
        self.distroID = distroID
        self.unitScope = unitScope
        self.alreadyConverged = alreadyConverged
        self.health = health
    }
}
