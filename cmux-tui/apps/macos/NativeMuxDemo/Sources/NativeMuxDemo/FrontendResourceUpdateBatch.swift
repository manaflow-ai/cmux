import Foundation

/// One bounded drain of ordered resource envelopes and its stream state.
struct FrontendResourceUpdateBatch: Sendable {
  let envelopes: [Data]
  let overflowed: Bool
  let ended: Bool
}
