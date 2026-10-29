import AppKit
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
        let row = priorityRow(SidebarPriorityEntry(id: "chat", title: "Fix the build", state: .idle, harness: "unknown-harness",
                                                   agentColor: SidebarItemInfo.stableAgentColor(for: "chat")))
        let mark = try #require(row.subviews.compactMap { $0 as? DecorativeImageView }.first)
        #expect(mark.image != nil, "an unknown harness still draws a mark")
        let inset = SidebarStyle.horizontalInset
        #expect(abs(mark.frame.midX - SidebarStyle.iconColumnCenterX(leading: inset)) < 0.5)
        let title = try #require(row.subviews.compactMap { $0 as? ChromeLabel }.first { $0.stringValue == "Fix the build" })
        #expect(abs(title.frame.minX - SidebarStyle.leadingTextX(leading: inset)) < 0.5)
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
