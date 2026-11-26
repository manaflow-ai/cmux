package import CmuxNextCompat
import Foundation

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

    /// Probes in a row a page may leave unanswered before it counts as idle (the crate's
    /// `ProbeHistory::UNANSWERED_LIMIT`).
    package static let unansweredLimit = 3
    /// The history lives in Rust, one per app: each instance keeps its pages apart by this prefix.
    private let scope = UUID().uuidString + ":"

    package init() {}

    /// Records a probe of page `key` and returns whether the page still gets the benefit of the
    /// doubt for `step` (always false for an answer; true when the rules do not answer).
    package mutating func record(_ probe: PageProbe, for key: String, step: Step = .discard) -> Bool {
        let reply = TabDiscardRules.call("tab_discard_record", ["key": scope + key, "probe": TabDiscardRules.wire(probe),
                                                                "step": TabDiscardRules.wire(step)])
        return reply?["doubted"] as? Bool ?? !probe.answered
    }

    /// Records the probe a freeze asked and returns whether the page stays awake: it does
    /// something a freeze stops, or it still gets the benefit of the doubt (`tab_discard_freeze_probe`).
    package mutating func freezeKeeps(_ probe: PageProbe, for key: String) -> Bool {
        let reply = TabDiscardRules.call("tab_discard_freeze_probe", ["key": scope + key, "probe": TabDiscardRules.wire(probe)])
        return reply?["keep"] as? Bool ?? true
    }

    /// Records the answer a discard asked (a miss is the freeze probe's to count) and returns why
    /// the page stays loaded, or nil when it may go (`tab_discard_probe`; `.unsupported` when the
    /// rules do not answer).
    package mutating func discardKeeps(_ probe: PageProbe, for key: String, pressure: MemoryPressureLevel,
                                       showsFormSubmission: Bool) -> HibernationPlanner.Exemption? {
        guard let reply = TabDiscardRules.call("tab_discard_probe", [
            "key": scope + key, "probe": TabDiscardRules.wire(probe), "pressure": pressure.rawValue,
            "shows_form_submission": showsFormSubmission,
        ]) else { return .unsupported }
        return reply["exemption"] is NSNull ? nil : TabDiscardRules.exemption(reply["exemption"]) ?? .unsupported
    }

    /// True while page `key` still gets the benefit of the doubt for `step`, without counting a probe.
    package func doubted(_ key: String, for step: Step = .discard) -> Bool {
        let reply = TabDiscardRules.call("tab_discard_probe_doubted", ["key": scope + key, "step": TabDiscardRules.wire(step)])
        return reply?["doubted"] as? Bool ?? true
    }

    /// The page was shown: its misses start again (what it last said still holds).
    package mutating func clearMisses(_ key: String) {
        _ = TabDiscardRules.call("tab_discard_shown", ["key": scope + key])
    }

    package mutating func forget(_ key: String) {
        _ = TabDiscardRules.call("tab_discard_forget", ["key": scope + key])
    }
}
