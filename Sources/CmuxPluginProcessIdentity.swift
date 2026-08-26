import Darwin
import Foundation

/// Binds a supervised PID to one process instance, not just its numeric PID.
/// The UUID protects delayed callbacks; the kernel start time protects socket
/// lookups after macOS reuses the PID.
struct CmuxPluginProcessIdentity: Equatable, Sendable {
    let generation: UUID
    let startMicroseconds: Int64
    let processGroupID: pid_t
}
