struct RemoteHookSnapshot: Decodable {
    let agent: String
    let action: String
    let arguments: [String]
    let entries: [RemoteHookSnapshotEntry]
}
