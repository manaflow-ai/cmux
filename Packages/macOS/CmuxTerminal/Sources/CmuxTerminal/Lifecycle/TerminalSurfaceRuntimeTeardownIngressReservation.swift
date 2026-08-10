import Foundation

internal struct TerminalSurfaceRuntimeTeardownIngressReservation: Sendable {
  let id: UUID

  init(id: UUID = UUID()) {
    self.id = id
  }
}
