public import CmuxLink

/// Classifies the selected ICE candidate pair into a path kind: a relay
/// candidate on either end means the bytes go through TURN; host, srflx and
/// prflx pairs are peer to peer (b2-webrtc.md section 7).
public struct CandidatePairClassifier: Sendable {
    public init() {}

    public func kind(local: CandidateType, remote: CandidateType) -> PathKind {
        local == .relay || remote == .relay ? .turn : .p2p
    }

    /// From the two candidate lines; nil when either has no `typ`.
    public func kind(localLine: String, remoteLine: String) -> PathKind? {
        guard let local = CandidateType(candidateLine: localLine),
              let remote = CandidateType(candidateLine: remoteLine) else { return nil }
        return kind(local: local, remote: remote)
    }
}
