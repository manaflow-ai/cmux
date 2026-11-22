import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// `experiments.agentBadges` on sidebar rows (taste build 5). Leo: "sidebar rows get one tinted status pill (Running,
/// Needs approval, Done); variant: a thin light beam travels along the row edge while an agent runs." Off by default,
/// and off draws the shipped row.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarAgentPillTests {
    static let id = WorkspaceID("pill-row")

    /// The row's state, one per pill and the states that show none.
    static func workspace(_ state: String) -> SidebarWorkspace {
        var ws: SidebarWorkspace
        switch state {
        case "running": ws = SidebarWorkspace(id: id, title: "Sidebar polish", agentWorking: true, activity: .working(progress: nil))
        case "needsApproval": ws = SidebarWorkspace(id: id, title: "Sidebar polish", activity: .waiting(kind: nil))
        case "done":
            ws = SidebarWorkspace(id: id, title: "Sidebar polish", unread: .dot)
            ws.agentChip = .done
        case "failed": ws = SidebarWorkspace(id: id, title: "Sidebar polish", activity: .error)
        default: ws = SidebarWorkspace(id: id, title: "Sidebar polish")
        }
        return ws
    }

    static let states = ["idle", "running", "needsApproval", "done", "failed"]

    /// The two Settings > Advanced > Experiments switches pick the arm; the beam alone turns nothing on.
    @Test func theSwitchesPickTheArm() {
        #expect(AgentBadgesExperiment(switches: [:]) == .off)
        #expect(AgentBadgesExperiment(switches: ["agentBadgesBeam": true]) == .off)
        #expect(AgentBadgesExperiment(switches: ["agentBadges": true]) == .pills)
        #expect(AgentBadgesExperiment(switches: ["agentBadges": true, "agentBadgesBeam": false]) == .pills)
        #expect(AgentBadgesExperiment(switches: ["agentBadges": true, "agentBadgesBeam": true]) == .beam)
    }

    static func withExperiment<T>(_ experiment: AgentBadgesExperiment, _ body: () throws -> T) rethrows -> T {
        let before = DesignSettings.shared.agentBadges
        DesignSettings.shared.agentBadges = experiment
        SidebarTunablesWatch.shared.changed()
        defer {
            DesignSettings.shared.agentBadges = before
            SidebarTunablesWatch.shared.changed()
        }
        return try body()
    }

    /// A sidebar showing `ws` alone, laid out in a window 260 pt wide.
    static func row(_ ws: SidebarWorkspace) throws -> (WorkspaceRowView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws)])])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        return (row, window)
    }

    /// The pill maps from the state the row already has; idle, failed and lost rows show none (their shipped mark).
    @Test func eachStateMapsToItsPill() {
        #expect(SidebarAgentPill.of(Self.workspace("idle")) == nil)
        #expect(SidebarAgentPill.of(Self.workspace("running")) == .running)
        #expect(SidebarAgentPill.of(Self.workspace("needsApproval")) == .needsApproval)
        #expect(SidebarAgentPill.of(Self.workspace("done")) == .done)
        #expect(SidebarAgentPill.of(Self.workspace("failed")) == nil)

        var asks = Self.workspace("running")
        asks.agentChip = .needsYou
        #expect(SidebarAgentPill.of(asks) == .needsApproval, "waiting on the person wins over work")
        var works = SidebarWorkspace(id: Self.id, title: "w")
        works.agentChip = .working(since: nil)
        #expect(SidebarAgentPill.of(works) == .running)
        var finishedRead = SidebarWorkspace(id: Self.id, title: "w", activity: .success)
        #expect(SidebarAgentPill.of(finishedRead) == nil, "a finish the person has seen is idle")
        finishedRead.unread = .dot
        #expect(SidebarAgentPill.of(finishedRead) == .done)
        var lost = SidebarWorkspace(id: Self.id, title: "w")
        lost.agentChip = .lost
        #expect(SidebarAgentPill.of(lost) == nil)
    }

    /// Leo's words, sentence case.
    @Test func thePillsSayLeosWords() {
        #expect(SidebarAgentPill.running.title == "Running")
        #expect(SidebarAgentPill.needsApproval.title == "Needs approval")
        #expect(SidebarAgentPill.done.title == "Done")
    }

    /// The reserve is the widest pill's, whatever the label: every pill fits and none is wider.
    @Test func theReservedWidthIsTheWidestPillsWhateverTheLabel() {
        let font = SidebarAgentPill.font
        let reserve = SidebarAgentPill.reservedWidth(font: font)
        let widths = SidebarAgentPill.allCases.map { $0.width(font: font) }
        #expect(reserve == widths.max())
        for pill in SidebarAgentPill.allCases { #expect(pill.width(font: font) <= reserve, "\(pill) overflows the slot") }
        #expect(SidebarAgentPill.needsApproval.width(font: font) == reserve, "Needs approval is the widest in English")
        #expect(SidebarAgentPill.reservedWidth(font: font) == reserve, "a second read is the same")
    }

    /// No layout shift: with the pills on, the title ends and the pill's slot sits at the same x in every state.
    @Test func theTitleEndsAtTheSameXInEveryState() throws {
        try Self.withExperiment(.pills) {
            var titleEnds: [String: CGFloat] = [:], slots: [String: NSRect] = [:]
            for state in Self.states {
                let (row, window) = try Self.row(Self.workspace(state))
                defer { window.close() }
                titleEnds[state] = row.title.frame.maxX
                let pillView = try #require(row.agentPillView)
                slots[state] = pillView.frame
                #expect(pillView.pill == SidebarAgentPill.of(Self.workspace(state)), "\(state)")
                if pillView.pill != nil {
                    #expect(row.activity.isHidden || !row.activity.showsGlyph, "\(state): the status glyph shows beside its pill")
                    #expect(row.rowBadge.isHidden, "\(state): the badge shows beside its pill")
                    let label = row.accessibilityLabel() ?? ""
                    #expect(label.contains(pillView.pill?.title ?? "-"), "\(state): the label does not say the pill: \(label)")
                }
            }
            let ends = Set(titleEnds.values)
            #expect(ends.count == 1, "the title's end moved with the state: \(titleEnds)")
            #expect(Set(slots.values.map { "\($0)" }).count == 1, "the pill's slot moved with the state: \(slots)")
            let slot = try #require(slots["idle"])
            #expect((ends.first ?? .infinity) <= slot.minX, "the title runs under the pill's slot")
        }
    }

    /// Off: the shipped row. No pill or beam view is made and the title runs as far as it did.
    @Test func offMakesNoViewsAndReservesNothing() throws {
        let offEnd: CGFloat = try Self.withExperiment(.off) {
            let (row, window) = try Self.row(Self.workspace("idle"))
            defer { window.close() }
            #expect(row.agentPillView == nil)
            #expect(row.agentBeamView == nil)
            return row.title.frame.maxX
        }
        let onEnd: CGFloat = try Self.withExperiment(.pills) {
            let (row, window) = try Self.row(Self.workspace("idle"))
            defer { window.close() }
            return row.title.frame.maxX
        }
        #expect(onEnd < offEnd, "the pills' slot reserves room only while they are on")
    }

    /// The beam runs only while the row's agent runs, and stops the moment it stops.
    @Test func theBeamStopsWhenTheRowStopsRunning() throws {
        try Self.withExperiment(.beam) {
            let (row, window) = try Self.row(Self.workspace("running"))
            defer { window.close() }
            let beam = try #require(row.agentBeamView)
            #expect(beam.isRunning)
            #expect(!beam.isHidden)
            let sidebarRow = try #require(row.lastConfiguration?.1)
            row.configure(Self.workspace("needsApproval"), row: sidebarRow)
            row.layoutSubtreeIfNeeded()
            #expect(!beam.isRunning)
            #expect(beam.isHidden)
            #expect(!beam.laps, "a stopped row keeps its lap")
        }
    }
}
