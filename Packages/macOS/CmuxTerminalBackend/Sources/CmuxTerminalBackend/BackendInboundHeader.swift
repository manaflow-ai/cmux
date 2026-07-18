struct BackendInboundHeader: Decodable {
    let id: UInt64?
    let event: String?
    let ok: Bool?
    let error: String?
}
