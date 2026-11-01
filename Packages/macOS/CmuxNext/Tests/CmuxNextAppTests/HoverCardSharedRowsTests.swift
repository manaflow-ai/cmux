import AppKit
@testable import CmuxNextDesign
import CmuxNextResources
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-19: the tab card and the session card share one row (`HoverCardRowView`) and read
/// like Codex's sidebar card: a remote machine's link as a dot (and how it is not connected, in
/// its color), CPU as bars, a blank page with no "about:blank", a terminal's exit status.
@MainActor @Suite(.serialized) struct HoverCardSharedRowsTests {
    private func workspace() -> SidebarWorkspace {
        var workspace = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("ws-remote"), machineID: CmuxNextSidebar.MachineID("air-blue"), title: "Deploy the docs")
        workspace.directory = "~/code/docs"
        return workspace
    }

    @Test(arguments: [SidebarMachine.Status.connected, .offline, .unreachable, .reconnecting])
    func aRemoteMachinesRowSaysWhetherItIsReachable(status: SidebarMachine.Status) throws {
        let machine = SidebarMachine(id: CmuxNextSidebar.MachineID("air-blue"), name: "air-blue", kind: .ssh, status: status)
        let facts = WorkspaceHoverCardContent.make(workspace(), machine: machine, now: Date()).facts
        let row = try #require(facts.first { $0.kind == "machine" })
        let tone = WorkspaceHoverCardContent.connectionTone(status)
        #expect(row.accessory == .dot(tone))
        let word = facts.first { $0.kind == "machineStatus" }
        if status == .connected {
            #expect(tone == .success)
            #expect(word == nil)
        } else {
            #expect(tone != .success)
            #expect(word?.ink == tone, "\(status): \(String(describing: word))")
            #expect(word?.text == WorkspaceHoverCardContent.connectionWord(status))
        }
    }

    @Test func theFactRowsAreTheSharedRow() {
        let machine = SidebarMachine(id: CmuxNextSidebar.MachineID("air-blue"), name: "air-blue", kind: .ssh, status: .offline)
        let card = WorkspaceHoverCardView()
        card.configure(.make(workspace(), machine: machine, now: Date()))
        card.detailsToggle.performClick(nil)
        #expect(card.lines.contains("air-blue"))
        #expect(card.lines.contains(CmuxNextSidebar.Strings.statusOffline))
        #expect(Self.rows(in: card).count >= 3)
    }

    @Test func busyCPUShowsAsWarmBars() throws {
        let busy = ResourceReport(total: ResourceUsage(cpu: 2.4, memoryBytes: 2 << 30), processCount: 3)
        let row = try #require(WorkspaceHoverCardContent.resourceRow(busy, history: [0.5, 1.2, 2.4]))
        guard case .bars(let bars, let tone)? = row.accessory else { Issue.record("no bars: \(row)"); return }
        #expect(tone == .danger)
        #expect(bars.count == 3 && bars.last == 1)
        let quiet = ResourceReport(total: ResourceUsage(cpu: 0.01, memoryBytes: 10 << 20), processCount: 1)
        #expect(WorkspaceHoverCardContent.resourceRow(quiet, history: [0.01]) == nil)
    }

    @Test func aBlankPageHasNoAddressForATitleOrPlace() {
        var blank = TabItem(id: TabID("blank"), title: "about:blank", subtitle: "about:blank")
        blank.hover = TabHoverFacts(kind: .browser)
        let lines = TabHoverCardLines.make(blank, report: nil, now: Date())
        #expect(lines.title == CmuxNextTabs.Strings.untitled)
        #expect(lines.place == nil)
    }

    @Test func aTerminalTitledByItsFolderSaysTheFolderOnce() {
        var shell = TabItem(id: TabID("home"), title: "~", subtitle: "~")
        shell.hover = TabHoverFacts(kind: .terminal)
        #expect(TabHoverCardLines.make(shell, report: nil, now: Date()).place == nil)
        shell.title = "cargo build"
        #expect(TabHoverCardLines.make(shell, report: nil, now: Date()).place == "~")
    }

    @Test func aTerminalSaysHowItsLastCommandEnded() {
        var failed = TabItem(id: TabID("t-failed"), title: "swift test", status: .failure)
        failed.hover = TabHoverFacts(kind: .terminal)
        #expect(TabHoverCardLines.make(failed, report: nil, now: Date()).status == CmuxNextTabs.Strings.axFailure)
        #expect(TabHoverCardLines.tone(failed) == .danger)
        var done = failed
        done.status = .success
        #expect(TabHoverCardLines.make(done, report: nil, now: Date()).status == CmuxNextTabs.Strings.axSuccess)
        #expect(TabHoverCardLines.tone(done) == .success)
    }

    @Test func theTabCardsRowsAreTheSharedRowIn13Points() {
        var item = TabItem(id: TabID("t"), title: "cargo build", subtitle: "~/Projects/cmux")
        item.hover = TabHoverFacts(kind: .terminal, activity: .running, since: Date().addingTimeInterval(-5))
        let card = TabHoverCardView()
        card.configure(.tab(item))
        let rows = Self.rows(in: card).filter { !$0.isHidden }
        #expect(rows.count == 3, "place, status and the memory dash: \(card.reportedLines)")
        #expect(rows.allSatisfy { $0.textLabel.font?.pointSize == Typography.body.pointSize })
    }

    @Test(arguments: [true, false])
    func theGalleryShowsEveryKind(tabs: Bool) {
        let cards = tabs ? TabHoverCardGallery.cards() : WorkspaceHoverCardGallery.cards()
        // The sidebar adds a chat that never left the home folder (no folder line, Leo 2026-10-21),
        // and one running-work card per `WorkspaceHoverCardWork.Style` (#30439).
        let count = tabs ? 5 : 10 + WorkspaceHoverCardWork.Style.allCases.count
        #expect(cards.count == count)
        #expect(Set(cards.map(\.name)).count == count)
    }

    private static func rows(in view: NSView) -> [HoverCardRowView] {
        var out: [HoverCardRowView] = []
        var pending: [NSView] = [view]
        while let next = pending.popLast() {
            if let row = next as? HoverCardRowView { out.append(row) }
            pending.append(contentsOf: next.subviews)
        }
        return out
    }
}
