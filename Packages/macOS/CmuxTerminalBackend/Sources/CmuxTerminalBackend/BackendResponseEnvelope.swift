struct BackendResponseEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let id: UInt64?
    let ok: Bool
    let data: Payload?
    let error: String?
}
