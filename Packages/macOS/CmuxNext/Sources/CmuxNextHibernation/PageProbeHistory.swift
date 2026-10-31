/// What the hidden pages' recent probes said: the benefit of the doubt a page keeps while it does
/// not answer (plans/cmux-next/tab-lifecycle.md, section 3).
///
/// A page that does not answer (a script error, or no reply within the probe's deadline) counts as
/// idle once it missed `unansweredLimit` probes in a row: one miss can be a load or a pause of a few
/// seconds; three in a row mean a page busy the whole time, the one that costs the most to keep
/// awake. A page whose last answer said it holds something the step would break keeps the doubt
/// for as long as it does not answer, because only the page knows those and it is not answering:
/// for a discard, the person's form input, a `beforeunload` that asks, capture, Web Audio or a
/// WebRTC connection; for a freeze (which keeps memory and state), only what stops while frozen.
package struct PageProbeHistory {
    /// What the doubt is for.
    package enum Step {
        /// Freezing a hidden page: its timers, tasks and rendering stop; memory and state stay.
        case freeze
        /// Discarding (hibernating) a hidden page: its engine page closes.
        case discard
    }

    /// Probes in a row a page may leave unanswered before it counts as idle.
    package static let unansweredLimit = 3
    /// Probes in a row each page did not answer.
    private var unanswered: [String: Int] = [:]
    /// Each page's last answer.
    private var lastAnswer: [String: PageProbe] = [:]

    package init() {}

    /// Records a probe of page `key` and returns whether the page still gets the benefit of the
    /// doubt for `step` (always false for an answer).
    package mutating func record(_ probe: PageProbe, for key: String, step: Step = .discard) -> Bool {
        guard !probe.answered else {
            unanswered[key] = nil
            lastAnswer[key] = probe
            return false
        }
        if !saidBusy(key, for: step) { unanswered[key, default: 0] += 1 }
        return doubted(key, for: step)
    }

    /// True while page `key` still gets the benefit of the doubt for `step`, without counting a probe.
    package func doubted(_ key: String, for step: Step = .discard) -> Bool {
        saidBusy(key, for: step) || unanswered[key, default: 0] < Self.unansweredLimit
    }

    /// The page was shown: its misses start again (what it last said still holds).
    package mutating func clearMisses(_ key: String) {
        unanswered[key] = nil
    }

    package mutating func forget(_ key: String) {
        unanswered[key] = nil
        lastAnswer[key] = nil
    }

    private func saidBusy(_ key: String, for step: Step) -> Bool {
        guard let last = lastAnswer[key] else { return false }
        switch step {
        case .freeze: return last.stopsWhenFrozen
        case .discard: return last.exemption != nil
        }
    }
}
