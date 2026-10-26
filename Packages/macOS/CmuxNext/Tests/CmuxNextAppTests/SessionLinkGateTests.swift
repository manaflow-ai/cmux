import CmuxNextOnboarding
import Testing

/// A `cmux://session/<id>` link (any page or app can open one) only reveals a tab that already
/// shows the session; a new tab on it opens only after the person answers a question that names
/// the session, and a session acpmux does not have is refused without one.
@MainActor @Suite struct SessionLinkGateTests {
    final class Probe {
        var events: [String] = []
    }

    nonisolated let known = SessionLinkSubject(id: "ses-1", title: "Fix the sidebar", harness: "claude", host: "huge-blue")

    func gate(_ probe: Probe, answer: Bool) -> SessionLinkGate {
        SessionLinkGate(lookup: { [known] id in
            probe.events.append("lookup \(id)")
            return id == known.id ? known : nil
        }, askOpen: { subject in
            probe.events.append("ask \(subject.name) on \(subject.host)")
            return answer
        })
    }

    @Test func anExistingTabIsRevealedWithoutAQuestion() async {
        let probe = Probe()
        let outcome = await gate(probe, answer: false).open("ses-1", reveal: { probe.events.append("reveal"); return true },
                                                             openNew: { probe.events.append("open") }).value
        #expect(outcome == .revealed)
        #expect(probe.events == ["reveal"])
    }

    @Test func noTabAsksAndOpensOnlyAfterOpen() async {
        let probe = Probe()
        let outcome = await gate(probe, answer: true).open("ses-1", reveal: { false }, openNew: { probe.events.append("open") }).value
        #expect(outcome == .opened)
        #expect(probe.events == ["lookup ses-1", "ask Fix the sidebar on huge-blue", "open"])
    }

    @Test func cancelOpensNothing() async {
        let probe = Probe()
        let outcome = await gate(probe, answer: false).open("ses-1", reveal: { false }, openNew: { probe.events.append("open") }).value
        #expect(outcome == .cancelled)
        #expect(probe.events == ["lookup ses-1", "ask Fix the sidebar on huge-blue"])
    }

    @Test func anUnknownSessionIsRefusedWithoutAQuestion() async {
        let probe = Probe()
        let outcome = await gate(probe, answer: true).open("ses-nope", reveal: { false }, openNew: { probe.events.append("open") }).value
        #expect(outcome == .refused)
        #expect(probe.events == ["lookup ses-nope"])
    }

    @Test func theQuestionNamesTheTitleElseTheHarnessElseTheID() {
        #expect(SessionLinkSubject(id: "a", title: "T", harness: "codex", host: "This Mac").name == "T")
        #expect(SessionLinkSubject(id: "a", title: "", harness: "codex", host: "This Mac").name == "codex")
        #expect(SessionLinkSubject(id: "a", title: nil, harness: nil, host: "This Mac").name == "a")
    }
}
