/// A trickled ICE candidate (`signal.ice`).
public struct ICECandidateInit: Sendable, Hashable {
    /// The `candidate:` attribute line, at most 1024 characters.
    public var candidate: String
    public var sdpMid: String?
    public var sdpMLineIndex: Int?

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}
