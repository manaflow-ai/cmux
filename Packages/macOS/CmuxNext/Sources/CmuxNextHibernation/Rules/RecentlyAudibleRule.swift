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

nonisolated extension ContentDiscardPlanner.Plan {
    /// The keys among `keys` whose sound reason (``CannotDiscardReason/recentlyAudible``, or
    /// ``CannotDiscardReason/audio`` that no probe set) an owner still holds from an earlier plan
    /// while this plan gives none: the minute after the sound ran out, or the sound ended. The owner
    /// drops them, since merging each plan's reasons only adds. A due key keeps its reason until its
    /// probe answers.
    ///
    /// - Parameters:
    ///   - keys: The candidates of this plan.
    ///   - held: The reasons the owner reports now (`debug.surfaces`).
    ///   - probeKept: Whether a probe kept the key lately (its `.audio` is the probe's).
    package func endedSoundReasons(of keys: [String], held: [String: CannotDiscardReason],
                                   probeKept: (String) -> Bool) -> [String] {
        let dueKeys = Set(due)
        return keys.filter { key in
            guard exemptions[key] == nil, !dueKeys.contains(key) else { return false }
            switch held[key] {
            case .recentlyAudible?: return true
            case .audio?: return !probeKept(key)
            default: return false
            }
        }
    }
}
