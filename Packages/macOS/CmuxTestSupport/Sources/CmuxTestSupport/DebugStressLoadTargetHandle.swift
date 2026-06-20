#if DEBUG
public import Foundation

/// An opaque token identifying one queued terminal surface the stress harness is
/// driving to load.
///
/// The legacy harness queued a `DebugStressTerminalLoadTarget` value bundling a
/// `Workspace`, a pane id, a tab id, and a panel id. Those are all app-target
/// types, so ``DebugStressWorkspaceDriver`` instead carries an opaque
/// per-target token: the host mints one token per panel it preloaded, keeps the
/// mapping back to the live panel, and resolves it on each surface-start pass
/// and timeout log line.
///
/// Isolation: a pure `Sendable`, `Hashable` value. The `rawValue` is an
/// arbitrary host-assigned identifier; the driver only stores and returns it.
public struct DebugStressLoadTargetHandle: Sendable, Hashable {
    /// Host-assigned identifier of the queued surface. Opaque to the driver.
    public var rawValue: UUID

    /// Wraps a host-assigned identifier as a load-target handle.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
#endif
