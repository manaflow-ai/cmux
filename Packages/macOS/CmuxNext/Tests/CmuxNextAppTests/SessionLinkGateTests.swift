import AppKit
import CmuxNextOnboarding
import Testing

/// A `cmux://session/<id>` link (any page or app can open one) only reveals a tab that already
/// shows the session; a new tab on it opens only after the person answers a question that names
/// the session, and a session acpmux does not have is refused without one.
@MainActor @Suite struct SessionLinkGateTests {
    final class Probe {
        var events: [String] = []
        var askedIn: NSWindow?
        var shown = false
    }

    nonisolated let known = SessionLinkSubject(id: "ses-1", title: "Fix the sidebar", harness: "claude", host: "huge-blue")

    func gate(_ probe: Probe, answer: Bool) -> SessionLinkGate {
        SessionLinkGate(lookup: { [known] id in
            probe.events.append("lookup \(id)")
            return id == known.id ? known : nil
        }, askOpen: { subject, window in
            probe.events.append("ask \(subject.name) on \(subject.host)")
            probe.askedIn = window
            return answer
        })
    }

    @Test func anExistingTabIsRevealedWithoutAQuestion() async {
        let probe = Probe()
        let outcome = await gate(probe, answer: false).open("ses-1", in: nil, reveal: { probe.events.append("reveal"); return true },
                                                             openNew: { probe.events.append("open"); return true }).value
        #expect(outcome == .revealed)
        #expect(probe.events == ["reveal"])
    }

    @Test func noTabAsksAndOpensOnlyAfterOpen() async {
        let probe = Probe()
        let outcome = await gate(probe, answer: true).open("ses-1", in: nil, reveal: { false }, openNew: { probe.events.append("open"); return true }).value
        #expect(outcome == .opened)
        #expect(probe.events == ["lookup ses-1", "ask Fix the sidebar on huge-blue", "open"])
    }

    @Test func cancelOpensNothing() async {
        let probe = Probe()
        let outcome = await gate(probe, answer: false).open("ses-1", in: nil, reveal: { false }, openNew: { probe.events.append("open"); return true }).value
        #expect(outcome == .cancelled)
        #expect(probe.events == ["lookup ses-1", "ask Fix the sidebar on huge-blue"])
    }

    @Test func anUnknownSessionIsRefusedWithoutAQuestion() async {
        let probe = Probe()
        let outcome = await gate(probe, answer: true).open("ses-nope", in: nil, reveal: { false }, openNew: { probe.events.append("open"); return true }).value
        #expect(outcome == .refused)
        #expect(probe.events == ["lookup ses-nope"])
    }

    @Test func theQuestionNamesTheTitleElseTheHarnessElseTheID() {
        #expect(SessionLinkSubject(id: "a", title: "T", harness: "codex", host: "This Mac").name == "T")
        #expect(SessionLinkSubject(id: "a", title: "", harness: "codex", host: "This Mac").name == "codex")
        #expect(SessionLinkSubject(id: "a", title: nil, harness: nil, host: "This Mac").name == "a")
    }

    @Test func aTabThatOpenedWhileAskingIsRevealedNotDuplicated() async {
        let probe = Probe()
        let gate = SessionLinkGate(lookup: { [known] _ in known }, askOpen: { _, _ in probe.shown = true; return true })
        let outcome = await gate.open("ses-1", in: nil, reveal: { probe.events.append("reveal \(probe.shown)"); return probe.shown },
                                      openNew: { probe.events.append("open"); return true }).value
        #expect(outcome == .revealed)
        #expect(probe.events == ["reveal false", "reveal true"])
    }

    @Test func aPaneGoneByOpenOpensNothing() async {
        let probe = Probe()
        let outcome = await gate(probe, answer: true).open("ses-1", in: nil, reveal: { false }, openNew: { false }).value
        #expect(outcome == .cancelled)
    }

    @Test func theQuestionShowsInTheLinksWindow() async {
        let probe = Probe()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        _ = await gate(probe, answer: false).open("ses-1", in: window, reveal: { false }, openNew: { true }).value
        #expect(probe.askedIn === window)
    }

    @Test func aTitleCannotFakeALineOfTheQuestion() {
        let subject = SessionLinkSubject(id: "ses-9", title: "Fix\nMachine: This Mac\u{202E}gnp.exe", harness: "claude\u{200B}",
                                         host: "peer\t\tbox")
        #expect(subject.title == "Fix Machine: This Macgnp.exe")
        #expect(subject.harness == "claude")
        #expect(subject.host == "peer box")
        #expect(SessionLinkSubject(id: "a", title: String(repeating: "x", count: 500), harness: nil, host: "h").title?.count == 80)
        #expect(SessionLinkSubject(id: "a", title: " \n ", harness: nil, host: "h").name == "a")
        // One character with 100 000 combining accents is still a short line.
        let stacked = SessionLinkSubject(id: "a", title: "A" + String(repeating: "\u{0301}", count: 100_000), harness: nil, host: "h")
        #expect((stacked.title?.unicodeScalars.count ?? 0) <= 80 * 4 + 1)
        #expect(stacked.title?.hasSuffix("…") == true)
        // A pending space at the edge never pushes it over.
        let edge = SessionLinkSubject(id: "a", title: "A" + String(repeating: "\u{0301}", count: 318) + " \u{0301}", harness: nil, host: "h")
        #expect((edge.title?.unicodeScalars.count ?? 0) <= 80 * 4 + 1)
    }

    @Test func theQuestionAlwaysShowsTheSessionID() {
        let titled = SessionLinkGate.details(SessionLinkSubject(id: "ses-9", title: "Fix the sidebar", harness: "claude", host: "huge-blue"))
        #expect(titled == ["Agent: claude", "Machine: huge-blue", "Session: ses-9"])
        #expect(SessionLinkGate.details(SessionLinkSubject(id: "ses-9", title: nil, harness: nil, host: "This Mac")) == ["Machine: This Mac", "Session: ses-9"])
    }

    @Test func aWindowThatClosedBeforeTheQuestionOpensNothing() async {
        let closed = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        #expect(await SessionLinkGate.ask(known, in: closed) == false)
    }
}
