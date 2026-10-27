@testable import CmuxNextApp
import CmuxNextHibernation
import CmuxNextCompat
import CmuxNextSettings
import Testing

/// Memory Saver keep rules (Lawrence 2026-10-24, CLAUDE.md "Copy Chrome's performance model"): a hidden
/// page with audio, capture, the person's form input, a running download or a `beforeunload` handler
/// that asks is never discarded, at any memory pressure.
///
/// Before: a running Web Audio context kept a page only until critical pressure; a page whose
/// `beforeunload` asks ("Leave site? Changes you made may not be saved") was discarded like any
/// other, and a page that answered "form input" and then stopped answering (a busy renderer) was
/// discarded under pressure after three missed probes, its draft lost.
@MainActor @Suite struct MemorySaverKeepRulesTests {
    // MARK: Every pressure level

    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func aRunningWebAudioContextKeepsThePageAtEveryPressure(_ pressure: MemoryPressureLevel) {
        let probe = PageProbe(webAudio: true)
        #expect(probe.keepReason(pressure: pressure, doubted: false, showsFormSubmission: false) == .webAudio)
    }

    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func everyKeepReasonHoldsAtEveryPressure(_ pressure: MemoryPressureLevel) {
        let cases: [(PageProbe, HibernationPlanner.Exemption)] = [
            (PageProbe(playingMedia: true), .audio),
            (PageProbe(editedForm: true), .formInput),
            (PageProbe(capturing: true), .capturing),
            (PageProbe(beforeUnload: true), .beforeUnload),
            (PageProbe(webRTC: true), .webRTC),
            (PageProbe(connectedDevice: true), .connectedDevice),
            (PageProbe(unreadableFrame: true), .unreadableFrame),
        ]
        for (probe, reason) in cases {
            #expect(probe.keepReason(pressure: pressure, doubted: false, showsFormSubmission: false) == reason)
        }
        #expect(PageProbe().keepReason(pressure: pressure, doubted: false, showsFormSubmission: true) == .formSubmission)
    }

    /// A page that answered "the person's form input" and then stopped answering (its renderer busy)
    /// keeps the benefit of the doubt for as long as it does not answer: its draft is still there.
    @Test func aPageWhoseLastAnswerWasFormInputStaysWhileItDoesNotAnswer() {
        var history = PageProbeHistory()
        _ = history.record(PageProbe(editedForm: true), for: "page")
        for _ in 0..<(PageProbeHistory.unansweredLimit + 2) {
            let doubted = history.record(PageProbe(answered: false), for: "page")
            #expect(doubted, "a page with a draft lost the doubt")
        }
        let unanswered = PageProbe(answered: false)
        #expect(unanswered.keepReason(pressure: .critical, doubted: history.doubted("page"), showsFormSubmission: false) == .unanswered)
    }

    @Test(arguments: ["beforeUnload", "webRTC", "capturing", "webAudio"])
    func aPageWhoseLastAnswerSaidBusyStaysWhileItDoesNotAnswer(_ reason: String) {
        let busy = switch reason {
        case "beforeUnload": PageProbe(beforeUnload: true)
        case "webRTC": PageProbe(webRTC: true)
        case "capturing": PageProbe(capturing: true)
        default: PageProbe(webAudio: true)
        }
        var history = PageProbeHistory()
        _ = history.record(busy, for: "page")
        for _ in 0..<(PageProbeHistory.unansweredLimit + 2) { _ = history.record(PageProbe(answered: false), for: "page") }
        #expect(history.doubted("page"))
    }

    /// A page that never said it was busy loses the doubt after `unansweredLimit` misses in a row
    /// (the 2026-10-21 audit's 586 MB renderer), and an answer starts the count again.
    @Test func aPageThatNeverSaidItWasBusyLosesTheDoubt() {
        var history = PageProbeHistory()
        _ = history.record(PageProbe(), for: "page")
        for _ in 0..<PageProbeHistory.unansweredLimit { _ = history.record(PageProbe(answered: false), for: "page") }
        #expect(!history.doubted("page"))
        _ = history.record(PageProbe(), for: "page")
        #expect(history.doubted("page"))
    }
}

/// Chrome's kNotificationsEnabled: a proactive discard (the idle timeout) never takes a tab whose site
/// may show notifications, because a discarded page shows none; an urgent discard (memory pressure)
/// still may. cmux's WebKit tabs show web notifications (WebKitNotificationBridge); before, the
/// timeout discarded such a tab (a chat, a mail) and its notifications stopped.
@Suite struct MemorySaverNotificationsTests {
    private func page(_ key: String, notifications: Bool) -> HibernationPlanner.Candidate {
        HibernationPlanner.Candidate(key: key, hiddenFor: 3_600, allowsNotifications: notifications)
    }

    @Test func theTimeoutKeepsATabThatMayShowNotifications() {
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .normal, candidates: [
            page("chat", notifications: true), page("docs", notifications: false),
        ])
        #expect(plan.due == ["docs"])
        #expect(plan.exemptions["chat"]?.rawValue == "notifications")
    }

    @Test(arguments: [MemoryPressureLevel.warning, .critical])
    func memoryPressureMayStillTakeIt(_ pressure: MemoryPressureLevel) {
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: pressure, candidates: [page("chat", notifications: true)])
        #expect(plan.due == ["chat"])
    }
}
