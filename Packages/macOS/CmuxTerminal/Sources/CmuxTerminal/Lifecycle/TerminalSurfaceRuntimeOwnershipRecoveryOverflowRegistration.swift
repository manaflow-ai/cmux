/// Result of registering one surface with the bounded overflow recovery FIFO.
internal enum TerminalSurfaceRuntimeOwnershipRecoveryOverflowRegistration:
  Equatable, Sendable
{
  case registered(sequence: UInt64)
  case updated(sequence: UInt64)
  case rejected

  internal var sequence: UInt64? {
    switch self {
    case .registered(let sequence), .updated(let sequence):
      sequence
    case .rejected:
      nil
    }
  }
}
