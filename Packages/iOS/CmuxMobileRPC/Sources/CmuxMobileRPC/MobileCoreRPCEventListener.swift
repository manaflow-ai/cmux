import Foundation

struct MobileCoreRPCEventListener {
    let topics: Set<String>
    let continuation: AsyncStream<MobileEventEnvelope>.Continuation
}
