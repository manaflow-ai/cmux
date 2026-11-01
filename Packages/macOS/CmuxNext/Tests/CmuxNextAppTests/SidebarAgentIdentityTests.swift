import AppKit
import CmuxAgentBrands
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-29, on Priority and session rows that all drew one generic glyph: "all of these
/// icons that are literally all the same icon, that is terrible ... one of these is Codex, one of
/// these is Claude ... randomize the colors." Every agent row draws its harness mark, a harness
/// with no mark takes a stable per-session color, the row draws no routine status word, and a
/// workspace item's hover controls stay up while their menu is open.
@MainActor @Suite(.serialized)
struct SidebarAgentIdentityTests {
    private func priorityRow(_ entry: SidebarPriorityEntry) -> SidebarPriorityRowView {
        let row = SidebarPriorityRowView(entry: entry)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: SidebarPriorityRowView.height(hasPreview: entry.preview != nil))
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func shownText(_ view: NSView) -> [String] {
        view.subviews.compactMap { sub in sub.isHidden ? nil : (sub as? any ShownText)?.stringValue }.filter { !$0.isEmpty }
    }

    @Test func aSessionKeepsOneFallbackColorAndSessionsDiffer() {
        let ids = (0 ..< 12).map { "session-\($0)" }
        #expect(ids.map(SidebarItemInfo.stableAgentColor(for:)) == ids.map(SidebarItemInfo.stableAgentColor(for:)))
        #expect(Set(ids.map(SidebarItemInfo.stableAgentColor(for:))).count > 1, "sessions do not all share one color")
    }

    @Test func aPriorityRowDrawsItsAgentMarkOnTheSidebarColumns() throws {
        let row = priorityRow(SidebarPriorityEntry(id: "chat", title: "Fix the build", state: .idle, brand: nil,
                                                   agentColor: SidebarItemInfo.stableAgentColor(for: "chat")))
        let mark = try #require(row.subviews.compactMap { $0 as? DecorativeImageView }.first)
        #expect(mark.image != nil, "an unknown harness still draws a mark")
        let inset = SidebarStyle.horizontalInset
        #expect(abs(mark.frame.midX - SidebarStyle.iconColumnCenterX(leading: inset)) < 0.5)
        let title = try #require(row.subviews.compactMap { $0 as? ChromeLabel }.first { $0.stringValue == "Fix the build" })
        #expect(abs(title.frame.minX - SidebarStyle.leadingTextX(leading: inset)) < 0.5)
    }

    /// A harness id is not a brand id: `codex` draws the OpenAI mark only after the catalog maps it, so a raw
    /// `codex` reached the rows as no brand and drew the generic glyph beside Claude's mark.
    @Test func codexAndClaudeSessionsResolveToTheirOwnMarks() throws {
        let codex = try #require(SidebarItemInfo.agentBrand(forHarness: "codex"))
        let claude = try #require(SidebarItemInfo.agentBrand(forHarness: "claude"))
        #expect(codex != claude)
        #expect(AgentBrandCatalog.templateImage(brand: codex, size: SidebarStyle.kindGlyphSize) != nil)
        #expect(SidebarItemInfo.agentBrand(forHarness: "unknown-harness") == nil)
        let lanes = [("a", "codex"), ("b", "claude")].map { id, harness in
            AgentActivityLane(id: id, name: id, title: "Task " + id, peer: nil, parent: nil, state: .input,
                              since: Date(), error: nil, harness: harness)
        }
        let entries = AgentPriorityRanking().entries(lanes, marks: .init(), now: Date())
        #expect(Set(entries.compactMap(\.brand)) == [codex, claude])
        let chief = lanes.map { lane in
            AgentActivityLane(id: "id-optchat-sub-6b68ac4a-" + lane.id, name: "optchat-sub-6b68ac4a-" + lane.id, title: lane.title,
                              peer: nil, parent: "optchat-chief:6b68ac4a", state: .working, since: nil, error: nil, harness: lane.harness)
        }
        #expect(Set(SidebarTransientItem.chiefSubagents(lanes: chief, showsIdle: true).compactMap(\.info.brand)) == [codex, claude])
    }

    @Test func aPriorityRowDrawsNoStatusWords() {
        for state: SidebarPriorityEntry.State in [.needsYou, .done, .failed, .lost, .ciFailing, .idle] {
            let row = priorityRow(SidebarPriorityEntry(id: "chat", title: "Chat", state: state))
            let word = SidebarPriorityRowView.chipText(state, now: Date())
            #expect(!shownText(row).contains(word), "\(state): the row draws \(shownText(row))")
            #expect(row.accessibilityLabel()?.contains(word) == true, "\(state): the label still says it")
        }
        let since = Date().addingTimeInterval(-5 * 60)
        #expect(SidebarPriorityRowView.visibleChipText(.working(since: since), now: Date()) == SidebarPriorityRowView.elapsed(from: since, to: Date()))
    }

    @Test func aWorkspaceItemKeepsItsHoverControlsWhileItsMenuIsOpen() {
        let view = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        var info = SidebarItemInfo(title: "Workspace", symbol: "terminal")
        info.workspace = WorkspaceID("ws")
        view.configure(info, style: .list)
        #expect(!view.showsHoverActions, "no controls at rest")
        view.showsMenu = true
        #expect(view.showsHoverActions, "the open menu keeps its controls revealed")
        view.showsMenu = false
        #expect(!view.showsHoverActions)
    }
}
