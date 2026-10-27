// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The page uses the camera or microphone (Chrome's `kCapturingVideo` and `kCapturingAudio`; lead
    /// rule).
    package static let capturing = DiscardRule(.capturing, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.isCapturing
    }
}
