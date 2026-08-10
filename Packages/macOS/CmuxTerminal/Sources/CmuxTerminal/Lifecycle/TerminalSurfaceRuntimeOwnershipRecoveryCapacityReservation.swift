import Foundation

/// Atomically claims one open recovery-list slot for an overflow rescan.
nonisolated struct TerminalSurfaceRuntimeOwnershipRecoveryCapacityReservation:
  Sendable
{
  let id = UUID()
}
