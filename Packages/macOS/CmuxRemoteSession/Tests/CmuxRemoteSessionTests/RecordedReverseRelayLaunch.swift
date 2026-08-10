struct RecordedReverseRelayLaunch: Sendable {
    let arguments: [String]
    let localRelayPort: Int
    let startupMarker: String
}
