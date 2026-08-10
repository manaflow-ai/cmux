import Foundation

internal enum TerminalSurfaceRuntimeTeardownSubmission: Sendable {
  case enqueue(
    request: TerminalSurfaceRuntimeTeardownRequest,
    executionLane: TerminalSurfaceRuntimeTeardownExecutionLane,
    isolatedHibernationReservation: TerminalSurfaceRuntimeTeardownReservation?,
    ingressReservation: TerminalSurfaceRuntimeTeardownIngressReservation
  )
  case cancel(
    ticketID: UUID,
    result: AsyncStream<Bool>.Continuation,
    ingressReservation: TerminalSurfaceRuntimeTeardownIngressReservation
  )
  case cancelAll(
    ingressReservation: TerminalSurfaceRuntimeTeardownIngressReservation
  )
}
