import CmuxNextHibernation
@testable import CmuxNextPages
import Testing

/// The automatic keep reasons a page's own document sets (pageEdits.ts for every
/// page, the agent page's composer and dictation) reach ``PageLifecycle`` through
/// ``PageKeepReasons``, as Chrome's renderer reports form interaction, user edits and a
/// `beforeunload` handler (discard_eligibility_policy.cc): they block the discard, not the freeze,
/// and their end lets the pass run at once with no show or hide. Capture blocks both.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageLifecycleEditsTests {
    /// A page that logs its steps; its reasons are only its ``PageKeepReasons``.
    private final class EditsPage {
        let name: String
        let log: Log
        let keep = PageKeepReasons()

        init(_ name: String, log: Log) {
            self.name = name
            self.log = log
            keep.owner = self
        }
    }

    private final class Log {
        var lines: [String] = []
    }

    private struct Target: PageLifecycleTarget {
        let page: EditsPage
        var object: AnyObject? { page }
        var lifecycleGroup: String? { "viewer" }
        var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> { page.keep.current }

        func reportsReasonChanges(to lifecycle: PageLifecycle) { page.keep.lifecycle = lifecycle }
        func keepHideSnapshot() {}
        func dropHideSnapshot() {}
        func freeze() -> Bool {
            page.log.lines.append("freeze \(page.name)")
            return true
        }
        func thaw() { page.log.lines.append("thaw \(page.name)") }
        func discard() -> Bool {
            page.log.lines.append("discard \(page.name)")
            return true
        }
    }

    private let log = Log()
    private let rig = LifecycleDeadlineRig()
    private let lifecycle: PageLifecycle

    init() {
        lifecycle = PageLifecycle(deadlines: rig.scheduler)
    }

    private func page(_ name: String) -> EditsPage { EditsPage(name, log: log) }

    /// The one armed wake fires, then the frame its pass is posted in.
    private func fireDuePass(sourceLocation: SourceLocation = #_sourceLocation) throws {
        _ = try #require(lifecycle.nextPassAt, sourceLocation: sourceLocation)
        rig.fire()
    }

    /// Edits, form input, a `beforeunload` handler or an unsent draft let the hidden page freeze but
    /// keep it from its discard; their end (a save, a send, a route change) lets the discard run.
    @Test(arguments: ["user_edits", "form_interaction", "before_unload", "draft"])
    func aPagesOwnEditsLetItFreezeButKeepItFromItsDiscardUntilTheyEnd(_ name: String) throws {
        let reason = try #require(PageLifecyclePlanner.KeepReason(rawValue: name))
        #expect(PageKeepReasons.pageSettable.contains(reason), "the page cannot set \(name)")
        let editor = page("editor"), cloud = page("cloud")
        editor.keep.setFromPage(reason, on: true)
        lifecycle.hide("e", page: Target(page: editor))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "e") == .frozen, "\(name) kept the page from its freeze")
        try fireDuePass()
        #expect(lifecycle.state(of: "c") == .discarded)
        #expect(lifecycle.state(of: "e") == .frozen, "\(name) let the page be discarded")
        rig.advance(to: .seconds(400))
        editor.keep.setFromPage(reason, on: false)
        #expect(lifecycle.nextPassAt == .seconds(400), "the end of \(name) armed no pass")
        try fireDuePass()
        #expect(lifecycle.state(of: "e") == .discarded)
        #expect(log.lines == ["freeze editor", "discard cloud", "discard editor"])
    }

    /// Dictation in the page's own composer (`capture`) keeps the hidden page running until it ends.
    @Test func aPagesOwnCaptureKeepsItRunningUntilItEnds() throws {
        let chat = page("chat"), cloud = page("cloud")
        chat.keep.setFromPage(.capture, on: true)
        lifecycle.hide("h", page: Target(page: chat))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        rig.advance(to: .seconds(20))
        chat.keep.setFromPage(.capture, on: false)
        #expect(lifecycle.nextPassAt == .seconds(20))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(log.lines == ["freeze chat"])
    }
}
