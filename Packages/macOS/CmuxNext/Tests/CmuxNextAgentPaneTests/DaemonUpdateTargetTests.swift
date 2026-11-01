import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The words of the daemon update (``DaemonUpdateTarget``): how a build string reads, the ledger
/// that keeps one attempt per machine and build, the board, and the toggle.
@Suite(.closesItsWindows) nonisolated struct DaemonUpdateTargetTests {
    @Test func toggleIsOnByDefaultAndInDebugSettings() {
        #expect(AgentPaneTunables.updatePeersAutomatically.defaultValue)
        #expect(AgentPaneTunables.all.contains { $0.key == AgentPaneTunables.updatePeersAutomatically.key })
    }

    @Test func buildCommitReadsHashDirtyAndDate() throws {
        let clean = try #require(DaemonBuildCommit("ABC123DEF 2026-10-20"))
        #expect(clean.hash == "abc123def" && !clean.dirty && clean.date == "2026-10-20")
        #expect(DaemonBuildCommit("abc123def")?.date == nil)
        #expect(DaemonBuildCommit("abc123def 2026-1-20") == nil, "a second word that is no day")
        #expect(DaemonBuildCommit("abc123def 2026-10-20 extra") == nil)
        #expect(DaemonBuildCommit("abc123def+ 2026-10-20") == nil, "an empty suffix is not clean")
        #expect(DaemonBuildCommit("abc123def+wip 2026-10-20") == nil, "a suffix other than dirty.<8 hex>")
        #expect(DaemonBuildCommit("abc123def+dirty.123 2026-10-20") == nil)
        #expect(DaemonBuildCommit("abc12 2026-10-20") == nil, "a hash shorter than 7")
        #expect(try #require(DaemonBuildCommit("fedcba987 2026-10-21")).isNewer(than: clean))
        #expect(!clean.isNewer(than: try #require(DaemonBuildCommit("fedcba987 2026-10-21"))))
        #expect(!clean.isNewer(than: try #require(DaemonBuildCommit("fedcba987 2026-10-20"))), "one day orders nothing")
        #expect(!clean.isNewer(than: try #require(DaemonBuildCommit("fedcba987"))), "no date orders nothing")
        #expect(clean.sameCommit("abc123def0123456789abcdef0123456789abcd"))
        #expect(!clean.sameCommit("abc123dee0123456789abcdef0123456789abcd"))
        #expect(!clean.sameCommit(""), "nothing is no commit")
        #expect(!clean.sameCommit("abc"), "a prefix too short to name a commit")
        #expect(try #require(DaemonBuildCommit("abc123def+dirty.00ff00ff 2026-10-20")).dirty)
        #expect(DaemonBuildCommit("nogit 2026-10-20") == nil)
        #expect(DaemonBuildCommit(nil) == nil)
        #expect(DaemonBuildCommit("") == nil)
    }

    @Test func theLedgerKeepsOneBuildsOutcomesAcrossLaunches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def") == DaemonUpdateLedger(build: "abc123def"))
        try DaemonUpdateLedger(build: "abc123def", targets: ["acpmux-peer:huge-blue": "rolledBack"]).write(directory)
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def").targets == ["acpmux-peer:huge-blue": "rolledBack"])
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def").attempted("acpmux-peer:huge-blue"))
        #expect(!DaemonUpdateLedger.read(directory, build: "abc123def").attempted("acpmux-peer:cmux16"))
        // A new build starts an empty ledger.
        #expect(DaemonUpdateLedger.read(directory, build: "fedcba987").targets.isEmpty)
    }

    /// A machine that cannot update in place is kept across builds; a ledger written before that
    /// field still reads (it is no unreadable ledger that blocks every target).
    @Test func theLedgerKeepsCannotUpdateAcrossBuildsAndReadsAnOlderFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"build":"abc123def","targets":{"cloud:vm-1":"failed"}}"#.utf8).write(to: DaemonUpdateLedger.file(in: directory))
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def") == DaemonUpdateLedger(build: "abc123def", targets: ["cloud:vm-1": "failed"]))
        let tooOld = DaemonUpdateLedger.CannotUpdate(build: "0123456ff", reason: "too old to update in place")
        try DaemonUpdateLedger(build: "abc123def", targets: ["cloud:vm-1": "unsupported"], cannotUpdate: ["cloud:vm-1": tooOld]).write(directory)
        let next = DaemonUpdateLedger.read(directory, build: "fedcba987")
        #expect(next.targets.isEmpty)
        #expect(next.cannotUpdate == ["cloud:vm-1": tooOld])
    }

    /// A ledger file that is there but cannot be decoded may have held a rollback of this build:
    /// it blocks every target on this build (never retried), and the next build starts empty.
    @Test func anUnreadableLedgerBlocksItsBuildNotTheNext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"build":"abc123def","targets":{"acpmux-peer:huge-bl"#.utf8).write(to: DaemonUpdateLedger.file(in: directory))
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def").attempted("acpmux-peer:huge-blue"))
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def").attempted("cloud:vm-1"), "also after a relaunch")
        #expect(!DaemonUpdateLedger.read(directory, build: "fedcba987").attempted("acpmux-peer:huge-blue"))
    }

    @Test @MainActor func theBoardKeepsEachTargetsLatestStateAndForgetsACleared() {
        let board = DaemonUpdateBoard()
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16", state: .updating))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16", state: .retrying))
        #expect(board.targets["acpmux-peer:cmux16"]?.state == .retrying)
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", state: .cleared))
        #expect(board.targets.isEmpty)
    }

    /// An ssh machine's sidebar tooltip line: its target's latest state, found by host whatever its
    /// case, and none for a machine with no update state.
    @Test @MainActor func theBoardGivesAnSSHMachinesTooltipLine() {
        let board = DaemonUpdateBoard()
        #expect(board.detail(sshHost: "cmux16") == nil)
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16",
                                      state: .failed(reason: "disk full", rolledBack: false)))
        let line = DaemonUpdateBoard.line(.failed(reason: "disk full", rolledBack: false))
        #expect(line.contains("disk full"))
        #expect(board.detail(sshHost: "CMUX16") == line)
        #expect(board.detail(id: "acpmux-peer:cmux16") == line)
        #expect(board.detail(sshHost: "huge-blue") == nil)
        // Two targets on one host (an ssh peer and a Cloud machine reached over ssh): the lowest id's line.
        board.apply(DaemonUpdateEvent(id: "z-cloud:cmux16", displayName: "cmux16", sshHost: "cmux16", state: .updating))
        #expect(board.detail(sshHost: "cmux16") == line)
        #expect(DaemonUpdateBoard.line(.updated(build: "abc123def 2026-10-20")).contains("abc123def 2026-10-20"))
        #expect(DaemonUpdateBoard.line(.failed(reason: "new daemon reported 0123456ff", rolledBack: true)).contains("0123456ff"))
        #expect(!DaemonUpdateBoard.line(.updating).isEmpty && !DaemonUpdateBoard.line(.retrying).isEmpty)
    }

    /// A recorded failure or rollback the policy asks a notice for shows a toast naming the
    /// machine, with its reason in the toast's detail; the same state without the ask, or any
    /// other state, shows none. A successful update never shows one (Leo, 2026-10-30: "i dont
    /// think i need to see this").
    @Test @MainActor func aFailureTheBoardIsAskedToNoticeShowsOneToast() {
        let board = DaemonUpdateBoard()
        var shown: [CmuxToast] = []
        board.showNotice = { shown.append($0.toast); return nil }
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16", state: .updating, notify: true))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16",
                                      state: .updated(build: "46c97e9"), notify: true, build: "46c97e9"))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16",
                                      state: .failed(reason: "disk full", rolledBack: false)))
        #expect(shown.isEmpty)
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16",
                                      state: .failed(reason: "disk full", rolledBack: false), notify: true))
        #expect(shown.count == 1)
        #expect(shown.first?.message.contains("cmux16") == true && shown.first?.detail == "disk full")
        #expect(DaemonUpdateBoard.noticeToast([DaemonUpdateEvent(id: "x", displayName: "x", state: .updating, notify: true)]) == nil)
        #expect(DaemonUpdateBoard.noticeToast([DaemonUpdateEvent(id: "x", displayName: "x", state: .updated(build: "46c97e9"), notify: true)]) == nil)
    }

    /// Leo's screen: three toasts stacked over the chat list and composer, one per machine (a
    /// launchctl bootstrap 125, a rollback that failed too, another machine). Failures share one
    /// toast (one id, replaced in place) that names every machine, with each reason in its tooltip;
    /// closed, it stays closed for that build, also after a relaunch, and a later build's failure
    /// shows again.
    @Test @MainActor func failuresShareOneToastThatStaysClosedForItsBuild() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)/notice-closed")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var shown: [DaemonUpdateBoard.Notice] = []
        func board() async -> DaemonUpdateBoard {
            let board = DaemonUpdateBoard(closedNoticeFile: file)
            board.showNotice = { shown.append($0); return nil }
            await board.settled()
            return board
        }
        func failed(_ name: String, reason: String = "Bootstrap failed: 125: Domain does not support specified action",
                    build: String = "abc123def", rolledBack: Bool = false) -> DaemonUpdateEvent {
            DaemonUpdateEvent(id: "acpmux-peer:\(name)", displayName: name, sshHost: name,
                              state: .failed(reason: reason, rolledBack: rolledBack), notify: true, build: build)
        }
        let first = await board()
        first.apply(failed("lab-mini"))
        first.apply(failed("build-box", reason: "rollback failed too (125)", rolledBack: true))
        first.apply(failed("tidy-yellow-tern", reason: "the new daemon did not answer"))
        let ids = shown.map { $0.toast.id }
        #expect(Set(ids) == [DaemonUpdateBoard.noticeID], "a toast per machine: \(ids)")
        let grouped = try #require(shown.last?.toast)
        for name in ["lab-mini", "build-box", "tidy-yellow-tern"] {
            #expect(grouped.message.contains(name), "\(grouped.message)")
        }
        #expect(grouped.detail?.components(separatedBy: "\n").count == 3)
        #expect(grouped.detail?.contains("Bootstrap failed: 125") == true)
        #expect(grouped.duration == CmuxToast.untilClosed)
        #expect(grouped.action?.revealsDetails == true, "no Details button that shows the reasons in place")

        // Closed: no toast for this build again, in this run or after a relaunch.
        shown.last?.closed()
        first.apply(failed("cloud-vm"))
        await first.settled()
        let relaunched = await board()
        relaunched.apply(failed("lab-mini"))
        #expect(shown.count == 3, "a failure toast came back after it was closed for this build")
        // A later build's failure shows.
        relaunched.apply(failed("lab-mini", build: "fedcba987"))
        #expect(shown.count == 4)
        #expect(shown.last?.toast.message.contains("lab-mini") == true)
    }

    /// The closed build is read off the main actor: a failure that comes first waits for it, and
    /// shows only when its build is not the one closed in an earlier run.
    @Test @MainActor func aFailureBeforeTheClosedBuildIsReadWaitsForIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("notice-closed")
        try Data("abc123def".utf8).write(to: file)
        var shown: [String] = []
        func failed(build: String) -> DaemonUpdateEvent {
            DaemonUpdateEvent(id: "acpmux-peer:lab-mini", displayName: "lab-mini", state: .failed(reason: "disk full", rolledBack: false),
                              notify: true, build: build)
        }
        let closed = DaemonUpdateBoard(closedNoticeFile: file)
        closed.showNotice = { shown.append($0.toast.message); return nil }
        closed.apply(failed(build: "abc123def"))
        await closed.settled()
        #expect(shown.isEmpty, "a failure of the build closed in an earlier run showed")
        let later = DaemonUpdateBoard(closedNoticeFile: file)
        later.showNotice = { shown.append($0.toast.message); return nil }
        later.apply(failed(build: "fedcba987"))
        await later.settled()
        #expect(shown.count == 1)
    }

    /// A machine too old to update in place is no failure: never a toast, and Settings > Updates
    /// lists it in one row with the failures, each machine once.
    @Test @MainActor func aMachineThatCannotUpdateHasNoToastAndOneSettingsLine() {
        let board = DaemonUpdateBoard()
        var shown: [String] = []
        board.showNotice = { shown.append($0.toast.message); return nil }
        #expect(board.otherMachines == nil)
        let tooOld = "lofty-lemon-stoat runs a cmux too old to update in place. Its chats and terminals keep working."
        board.apply(DaemonUpdateEvent(id: "cloud:a", displayName: "lofty-lemon-stoat", state: .cannotUpdate(reason: tooOld), notify: true))
        board.apply(DaemonUpdateEvent(id: "cloud:a", displayName: "lofty-lemon-stoat", state: .cannotUpdate(reason: tooOld)))
        #expect(shown.isEmpty, "a toast for a machine that cannot update in place")
        #expect(board.detail(id: "cloud:a") == tooOld)
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:build-box", displayName: "build-box", sshHost: "build-box",
                                      state: .failed(reason: "disk full", rolledBack: false), notify: true, build: "abc123def"))
        #expect(shown.count == 1 && shown.first?.contains("lofty-lemon-stoat") == false)
        let machines = board.otherMachines
        #expect(machines?.lines.count == 2)
        #expect(machines?.lines.first == tooOld)
        #expect(machines?.lines.last?.contains("build-box") == true)
        // Updated since: off the list.
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:build-box", displayName: "build-box", state: .updated(build: "abc123def")))
        #expect(board.otherMachines?.lines == [tooOld])
    }

    /// Leo's screen: a toast "Couldn't update <machine>: ssh <machine> failed: ssh: connect to host
    /// <address> port 22: Operation timed out". A failure's headline names the machine in plain
    /// words; the CLI's text, its address included, stays in the detail.
    @Test func aFailuresHeadlineKeepsTheRawReasonInItsDetail() throws {
        let raw = "ssh swarm-10 failed: ssh: connect to host 192.0.2.7 port 22: No route to host"
        let failed = DaemonUpdateEvent(id: "acpmux-peer:swarm-10", displayName: "swarm-10",
                                       state: .failed(reason: raw, rolledBack: false), notify: true)
        let toast = try #require(DaemonUpdateBoard.noticeToast([failed]))
        #expect(toast.message == DaemonUpdateBoard.headline(failed))
        #expect(toast.message.contains("swarm-10") && !toast.message.contains("192.0.2.7") && !toast.message.contains("ssh"))
        #expect(toast.detail?.contains(raw) == true)
        let rolledBack = DaemonUpdateEvent(id: "acpmux-peer:b", displayName: "build-box",
                                           state: .failed(reason: "new daemon reported 0123456ff", rolledBack: true), notify: true)
        let kept = try #require(DaemonUpdateBoard.noticeToast([rolledBack]))
        #expect(kept.message.contains("build-box") && !kept.message.contains("0123456ff"))
        #expect(kept.detail?.contains("0123456ff") == true)
    }

    /// An offline machine is one quiet line in plain words, in its tooltip and in Settings >
    /// Updates, never a toast; once it updates the line goes.
    @Test @MainActor func anOfflineMachineHasOneQuietLineAndNoToast() {
        let board = DaemonUpdateBoard()
        var shown: [CmuxToast] = []
        board.showNotice = { shown.append($0.toast); return nil }
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:swarm-10", displayName: "swarm-10", sshHost: "swarm-10", state: .offline, notify: true))
        #expect(shown.isEmpty, "a toast for an offline machine")
        #expect(board.detail(sshHost: "swarm-10") == DaemonUpdateBoard.line(.offline))
        #expect(board.otherMachines?.lines == [DaemonUpdateBoard.offlineLine("swarm-10")])
        #expect(board.otherMachines?.machines.first?.canUpdate == false)
        #expect(DaemonUpdateBoard.offlineLine("swarm-10").contains("swarm-10"))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:swarm-10", displayName: "swarm-10", sshHost: "swarm-10", state: .updated(build: "abc123def")))
        #expect(board.otherMachines == nil)
    }

    /// Details shows the reason in the toast, never Settings (Leo 2026-10-29: "the FUCKING details
    /// are FUCKING STUPID BECAUSE IT TAKES YOU TO FUCKING SETTINGS????"): one machine's toast says
    /// what happened in plain words, and its reason is the detail Details shows.
    @Test func detailsShowTheReasonInTheToastNotSettings() throws {
        let event = DaemonUpdateEvent(id: "acpmux-peer:build-box", displayName: "build-box",
                                      state: .failed(reason: "disk full", rolledBack: false), notify: true)
        let toast = try #require(DaemonUpdateBoard.noticeToast([event]))
        #expect(toast.id == DaemonUpdateBoard.noticeID)
        #expect(toast.action?.revealsDetails == true)
        #expect(toast.message.contains("build-box") && !toast.message.contains("disk full"))
        #expect(toast.detail == "disk full", "the detail repeats the headline: \(toast.detail ?? "nil")")
        let rolledBack = DaemonUpdateEvent(id: "acpmux-peer:build-box", displayName: "build-box",
                                           state: .failed(reason: "the new daemon did not answer", rolledBack: true), notify: true)
        let kept = try #require(DaemonUpdateBoard.noticeToast([rolledBack]))
        #expect(kept.message.contains("build-box") && kept.detail == "the new daemon did not answer")
        #expect(kept.message != toast.message)
    }

    /// Only the person closes the notice for the build. Its window closing (the toast center ends
    /// its toasts as `closed`), a newer notice in its place, or a timeout leaves later failures
    /// free to show.
    @Test func onlyThePersonClosesTheNotice() {
        #expect(DaemonUpdateBoard.closedByPerson(.closed, windowShown: true))
        #expect(DaemonUpdateBoard.closedByPerson(.action, windowShown: true))
        #expect(!DaemonUpdateBoard.closedByPerson(.closed, windowShown: false), "a window closing closed the notice for the build")
        #expect(!DaemonUpdateBoard.closedByPerson(.replaced, windowShown: true))
        #expect(!DaemonUpdateBoard.closedByPerson(.timeout, windowShown: true))
    }

    /// One notice at a time, on real toast handles: a new failure in another window takes the old
    /// toast down, and a close that settles after a newer failure of its build showed (the close
    /// is read a turn later) takes that one down too, so nothing of a closed build stays up.
    @Test @MainActor func oneNoticeAtATimeAndACloseTakesDownALaterOneOfItsBuild() throws {
        let center = CmuxToastCenter(host: NoticeTestHost())
        let windows = (0..<2).map { _ in
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        }
        defer { windows.forEach { $0.closeAfterTest() } }
        var notices: [DaemonUpdateBoard.Notice] = []
        var handles: [CmuxToastHandle] = []
        let board = DaemonUpdateBoard()
        board.showNotice = { notice in
            notices.append(notice)
            let handle = center.show(notice.toast, in: windows[handles.count % 2])
            handles.append(handle)
            return handle
        }
        func failed(_ name: String) -> DaemonUpdateEvent {
            DaemonUpdateEvent(id: "acpmux-peer:\(name)", displayName: name, state: .failed(reason: "disk full", rolledBack: false),
                              notify: true, build: "abc123def")
        }
        board.apply(failed("lab-mini"))
        board.apply(failed("build-box"))
        let dismissed = handles.map { $0.isDismissed }
        #expect(dismissed == [true, false], "two notices up at once")
        #expect(center.toasts(in: windows[0]).isEmpty && center.toasts(in: windows[1]).count == 1)
        // The person closed the first; a third failure showed before that close was read.
        board.apply(failed("tidy-yellow-tern"))
        notices[0].closed()
        let up = handles.filter { !$0.isDismissed }.count
        #expect(up == 0, "a notice of a closed build stayed up")
        board.apply(failed("cloud-vm"))
        #expect(handles.count == 3, "a notice of a closed build showed again")
    }

    /// An update fails in the background, while the app is not active: AppKit then has no key and
    /// no main window, and the toast still goes to the app's frontmost workspace window, not nowhere.
    @Test @MainActor func aNoticeWithTheAppInTheBackgroundGoesToItsFrontWindow() {
        func window() -> NSWindow {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        }
        let behind = window(), front = window()
        defer { behind.closeAfterTest(); front.closeAfterTest() }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        defer { panel.closeAfterTest() }
        func rules(visible: Set<ObjectIdentifier>) -> DaemonUpdateBoard.NoticeWindowRules {
            var rules = DaemonUpdateBoard.NoticeWindowRules()
            rules.root = { $0 === panel ? front : $0 }
            rules.isWorkspace = { $0 === front || $0 === behind }
            rules.inView = { visible.contains(ObjectIdentifier($0)) }
            rules.shown = { visible.contains(ObjectIdentifier($0)) }
            return rules
        }
        let both: Set = [ObjectIdentifier(front), ObjectIdentifier(behind)]
        #expect(DaemonUpdateBoard.noticeWindow(key: nil, main: nil, ordered: [front, behind], rules: rules(visible: both)) === front)
        #expect(DaemonUpdateBoard.noticeWindow(key: nil, main: nil, ordered: [panel, behind], rules: rules(visible: both)) === front,
                "a panel stands for the window it is over")
        #expect(DaemonUpdateBoard.noticeWindow(key: nil, main: nil, ordered: [front, behind], rules: rules(visible: [ObjectIdentifier(behind)])) === behind,
                "a window that is not shown is skipped")
        #expect(DaemonUpdateBoard.noticeWindow(key: behind, main: front, ordered: [front], rules: rules(visible: both)) === behind, "the key window first")
        #expect(DaemonUpdateBoard.noticeWindow(key: nil, main: nil, ordered: [], rules: rules(visible: both)) == nil)
    }

    /// The notice goes to a workspace window, never to a settings, debug or page window, and a
    /// sheet, palette or panel stands for the window it is over. One in view on the active Space
    /// comes before one on another Space or minimized; that one still gets it when it is the only one.
    @Test @MainActor func aNoticeGoesToAWorkspaceWindowInView() {
        func window() -> NSWindow {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        }
        let workspace = window(), otherSpace = window(), settings = window(), sheet = window()
        defer { [workspace, otherSpace, settings, sheet].forEach { $0.closeAfterTest() } }
        var rules = DaemonUpdateBoard.NoticeWindowRules()
        rules.root = { $0 === sheet ? workspace : $0 }
        rules.isWorkspace = { $0 === workspace || $0 === otherSpace }
        rules.inView = { $0 === workspace }
        rules.shown = { _ in true }
        #expect(DaemonUpdateBoard.noticeWindow(key: settings, main: settings, ordered: [settings, workspace], rules: rules) === workspace,
                "settings is key, the workspace behind it takes the notice")
        #expect(DaemonUpdateBoard.noticeWindow(key: sheet, main: nil, ordered: [sheet], rules: rules) === workspace, "a sheet stands for its window")
        #expect(DaemonUpdateBoard.noticeWindow(key: otherSpace, main: nil, ordered: [otherSpace, workspace], rules: rules) === workspace,
                "one in view before one on another Space")
        #expect(DaemonUpdateBoard.noticeWindow(key: nil, main: nil, ordered: [settings, otherSpace], rules: rules) === otherSpace,
                "on another Space, or minimized, when it is the only workspace window")
        #expect(DaemonUpdateBoard.noticeWindow(key: settings, main: settings, ordered: [settings], rules: rules) == nil, "no workspace window, no notice")
    }
}

/// Toasts with no window overlay: the center's stacks and handles only.
@MainActor
private final class NoticeTestHost: CmuxToastHosting {
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {}
    func move(_ toast: CmuxToastView, to slot: Int) {}
    func hide(_ toast: CmuxToastView, animated: Bool) {}
}
