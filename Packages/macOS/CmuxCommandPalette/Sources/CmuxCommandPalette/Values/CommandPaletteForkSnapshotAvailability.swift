/// Whether a restorable agent snapshot can seed a "fork conversation" command,
/// and whether confirming that requires a per-agent fork-capability probe first.
public enum CommandPaletteForkSnapshotAvailability: Sendable {
    /// The snapshot cannot be forked (no fork command, or remote without startup input).
    case unsupported
    /// The snapshot is forkable and needs no per-agent capability probe.
    case supportedWithoutProbe
    /// The snapshot is forkable but a per-agent fork-capability probe must confirm it first.
    case requiresProbe
}
