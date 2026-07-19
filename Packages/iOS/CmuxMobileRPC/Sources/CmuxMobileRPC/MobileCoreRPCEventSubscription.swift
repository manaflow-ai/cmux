import Foundation

struct MobileCoreRPCEventSubscription {
    let id: UUID
    let stream: AsyncStream<MobileEventEnvelope>
}
