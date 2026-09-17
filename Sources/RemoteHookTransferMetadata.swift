struct RemoteHookTransferMetadata: Codable, Sendable {
    let arguments: [String]
    let environment: [String: String]
}
