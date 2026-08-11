import CCmuxTerminal
import Foundation

func drainFrontendResourceUpdates(
  maximumEnvelopes: Int = 64,
  maximumBytes: Int = 1_048_576,
  copy: (
    _ descriptor: inout CmuxFrontendResourceUpdate,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int
  ) -> Bool
) -> FrontendResourceUpdateBatch {
  var result: [Data] = []
  var ended = false
  var endReason = FrontendResourceStreamEndReason.none
  var retainedBytes = 0
  let envelopeBudget = max(1, maximumEnvelopes)
  let byteBudget = max(1, maximumBytes)
  while result.count < envelopeBudget {
    var descriptor = CmuxFrontendResourceUpdate()
    guard copy(&descriptor, nil, 0) else { break }
    ended = ended || descriptor.ended
    if descriptor.ended {
      endReason = FrontendResourceStreamEndReason(rawValue: descriptor.end_reason) ?? .error
    }
    if descriptor.overflowed {
      return FrontendResourceUpdateBatch(
        envelopes: [], hasMore: false, overflowed: true, ended: ended, endReason: endReason
      )
    }
    guard descriptor.payload_length > 0 else { break }
    if !result.isEmpty,
      descriptor.payload_length > byteBudget - min(retainedBytes, byteBudget)
    {
      return FrontendResourceUpdateBatch(
        envelopes: result,
        hasMore: true,
        overflowed: false,
        ended: false,
        endReason: .none
      )
    }
    var payload = Data(count: descriptor.payload_length)
    let copied = payload.withUnsafeMutableBytes { bytes in
      copy(
        &descriptor,
        bytes.bindMemory(to: UInt8.self).baseAddress,
        bytes.count
      )
    }
    guard copied else { break }
    ended = ended || descriptor.ended
    if descriptor.ended {
      endReason = FrontendResourceStreamEndReason(rawValue: descriptor.end_reason) ?? .error
    }
    if descriptor.overflowed {
      return FrontendResourceUpdateBatch(
        envelopes: [], hasMore: false, overflowed: true, ended: ended, endReason: endReason
      )
    }
    result.append(payload)
    retainedBytes += payload.count
  }
  let hasMore = result.count >= envelopeBudget || retainedBytes >= byteBudget
  return FrontendResourceUpdateBatch(
    envelopes: result,
    hasMore: hasMore,
    overflowed: false,
    ended: ended && !hasMore,
    endReason: hasMore ? .none : endReason
  )
}
