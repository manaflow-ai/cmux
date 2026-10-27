// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// A connected WebRTC peer connection: a discard would end the call (lead rule).
    package static let webRTC = DiscardRule(.webRTC, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.hasWebRTC
    }
}
