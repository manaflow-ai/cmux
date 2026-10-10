import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// cx-xub5 (Lawrence 2026-10-09): the three minimal All chats designs live in a tagged build
/// behind one TEMPORARY Debug picker (`sidebar.allChats.design`, default Age). Switching the picker
/// redraws the rows in that design.
@MainActor @Suite(.serialized) struct SidebarChatsDesignPickerTests {
    private func row(_ view: SidebarChatsView) throws -> SidebarChatRowView {
        view.layoutSubtreeIfNeeded()
        let table = view.chatTable
        let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarChatRowView)
        row.frame = NSRect(x: 0, y: 0, width: 260, height: Metrics.sidebarRowHeight)
        row.layout()
        return row
    }

    @Test func thePickerSwitchesTheRenderedDesign() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let view = SidebarChatsView(frame: NSRect(x: 0, y: 0, width: 260, height: 400),
                                    defaults: UserDefaults(suiteName: "chats-design-\(UUID())")!)
        view.now = { now }
        view.update([SidebarChatsView.Row(id: "codex:a", title: "Fix the build", harness: "codex", brand: "codex",
                                          folder: "/p/cmux", updatedAt: now.addingTimeInterval(-120))], enabled: true, ready: true)
        #expect(SidebarChatsDesign.tunable.defaultValue == .age, "Age is the default")

        view.design = .quiet
        var shown = try row(view)
        #expect(!shown.icon.isHidden && shown.meta.isHidden, "Quiet: the glyph, no trailing text")

        view.design = .age
        shown = try row(view)
        #expect(shown.icon.isHidden && !shown.meta.isHidden, "Age: no glyph, the age")
        #expect(shown.meta.stringValue == SidebarChatsDesign.age(from: now.addingTimeInterval(-120), to: now))
        // nxdog84: the age drew as "2..." (its frame lacked the field's insets).
        #expect(shown.meta.frame.width >= (shown.meta.cell?.cellSize.width ?? .infinity), "the age is not clipped")

        view.design = .project
        shown = try row(view)
        #expect(shown.icon.isHidden && shown.meta.stringValue == "· cmux", "Project: no glyph, the project")
        #expect(shown.meta.frame.minX >= shown.title.frame.maxX)
    }
}
