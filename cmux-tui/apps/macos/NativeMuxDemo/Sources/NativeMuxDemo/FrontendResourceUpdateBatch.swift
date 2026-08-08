import Foundation

enum FrontendResourceStreamEndReason: UInt32, Sendable {
  case none = 0
  case completed = 1
  case canceled = 2
  case closed = 3
  case gap = 4
  case error = 5
}

/// One bounded drain of ordered resource envelopes and its stream state.
struct FrontendResourceUpdateBatch: Sendable {
  let envelopes: [Data]
  let overflowed: Bool
  let ended: Bool
  let endReason: FrontendResourceStreamEndReason
}
