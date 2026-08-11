internal import Foundation

internal struct TerminalSurfaceRuntimeOwnershipRecoveryFailureDelivery: Sendable {
  internal let recoveryID: UUID
  internal let deliveryID: UUID
  internal let failure: TerminalSurfaceRuntimeOwnershipRecoveryFailure

  @MainActor
  internal func callAsFunction() {
    failure()
  }
}
