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
  while true {
    var descriptor = CmuxFrontendResourceUpdate()
    guard copy(&descriptor, nil, 0) else { break }
    ended = ended || descriptor.ended
    if descriptor.overflowed {
      return FrontendResourceUpdateBatch(envelopes: [], overflowed: true, ended: ended)
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
    if descriptor.overflowed {
      return FrontendResourceUpdateBatch(envelopes: [], overflowed: true, ended: ended)
    }
    result.append(payload)
  }
  return FrontendResourceUpdateBatch(envelopes: result, overflowed: false, ended: ended)
}
