import CCmuxTerminal
import Foundation

func drainFrontendResourceUpdates(
  copy: (
    _ descriptor: inout CmuxFrontendResourceUpdate,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int
  ) -> Bool
) -> FrontendResourceUpdateBatch {
  var result: [Data] = []
  var ended = false
  var endReason = FrontendResourceStreamEndReason.none
  while true {
    var descriptor = CmuxFrontendResourceUpdate()
    guard copy(&descriptor, nil, 0) else { break }
    ended = ended || descriptor.ended
    if descriptor.ended {
      endReason = FrontendResourceStreamEndReason(rawValue: descriptor.end_reason) ?? .error
    }
    if descriptor.overflowed {
      return FrontendResourceUpdateBatch(
        envelopes: [], overflowed: true, ended: ended, endReason: endReason
      )
    }
    guard descriptor.payload_length > 0 else { break }
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
        envelopes: [], overflowed: true, ended: ended, endReason: endReason
      )
    }
    result.append(payload)
  }
  return FrontendResourceUpdateBatch(
    envelopes: result, overflowed: false, ended: ended, endReason: endReason
  )
}
