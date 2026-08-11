import Foundation

internal struct TerminalSurfaceRuntimeActiveTeardown: Sendable {
  let ticketID: UUID
  let task: Task<Void, Never>
  let watchdogTask: Task<Void, Never>?
}
