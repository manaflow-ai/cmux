// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// Seconds after its sound ends that content stays protected: Chrome's `kTabAudioProtectionTime`
    /// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc), one minute.
    package static let audioProtectionTime: Double = 60

    /// The content's sound ended less than ``audioProtectionTime`` ago (Chrome's `kRecentlyAudible`):
    /// protected from the timeout and from memory pressure, so a paused song or a call between two
    /// sounds comes back as the person left it. The protection runs out with time alone, so its end
    /// is the planner's next look (`ContentDiscardPlanner.Plan.nextCheck`), not a timer of its own.
    package static let recentlyAudible = DiscardRule(.recentlyAudible, result: .protected, for: DiscardRule.pressure,
                                                     test: { candidate, _ in audioProtectionLeft(candidate) > 0 },
                                                     expiresIn: { audioProtectionLeft($0) })

    /// Seconds of audio protection `candidate` has left: 0 when it never played or its minute is over.
    ///
    /// - Parameter candidate: The content's facts (``ContentDiscardPlanner/Candidate/secondsSinceAudible``).
    package static func audioProtectionLeft(_ candidate: ContentDiscardPlanner.Candidate) -> Double {
        guard let since = candidate.secondsSinceAudible else { return 0 }
        return max(audioProtectionTime - max(since, 0), 0)
    }
}
