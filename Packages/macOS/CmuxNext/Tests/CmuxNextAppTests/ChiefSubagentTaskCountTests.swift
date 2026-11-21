import AppKit
import CmuxNextAgentActivity
import CmuxNextDesign
@testable import CmuxNextAgentLanes
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The Chief's subagent rows under the sidebar's top Chief row (cmux#48416 follow-up, "Chief replaces Home") show a
/// subagent's task count, as a chat row does (`SidebarTaskProgressTests`): a quiet "1/3" on the row's trailing side
/// while steps are left, nothing once the list is done or the `sidebar.taskProgress` setting is off.
@MainActor @Suite(.serialized) struct ChiefSubagentTaskCountTests {
    static func lane(_ name: String, _ state: AgentActivityLane.State, list: AgentTaskList?) -> AgentActivityLane {
        AgentActivityLane(id: "id-" + name, name: name, title: "Fix the build", peer: nil, parent: "optchat-chief:6b68ac4a",
                          state: state, since: nil, error: nil, harness: "claude", taskList: list)
    }

    static let open = AgentTaskList(source: .harness, done: 1, total: 3, current: "Fix the queue", next: "Land",
                                    updatedAt: Date(timeIntervalSince1970: 1))
    static let finished = AgentTaskList(source: .harness, done: 2, total: 2, updatedAt: Date(timeIntervalSince1970: 1))

    /// The row view the sidebar draws `item` with, laid out at a sidebar's width.
    static func drawn(_ item: SidebarTransientItem) -> SidebarItemRowView {
        _ = NSApplication.shared
        let view = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        view.configure(item.info, style: .builtIn)
        view.layoutSubtreeIfNeeded()
        view.layout()
        return view
    }

    /// The shown text of `view`'s labels (the sidebar's `ChromeLabel`s and any AppKit text field) with its frame.
    struct Shown { let stringValue: String; let frame: NSRect }
    static func shownTexts(_ view: NSView) -> [Shown] {
        view.subviews.flatMap { sub -> [Shown] in
            guard !sub.isHidden else { return [] }
            let text = (sub as? ChromeLabel)?.stringValue ?? (sub as? NSTextField)?.stringValue
            return (text.map { [Shown(stringValue: $0, frame: sub.frame)] } ?? []) + shownTexts(sub)
        }
    }

    static func rows(_ lanes: [AgentActivityLane]) -> [SidebarTransientItem] {
        SidebarTransientItem.chiefSubagents(lanes: lanes, showsIdle: true)
    }

    @Test func aSubagentWithStepsLeftShowsItsCountBesideItsTitle() throws {
        try SidebarTaskProgressTests.withTaskProgress(nil) {
            let item = try #require(Self.rows([Self.lane("optchat-sub-6b68ac4a-a2", .working, list: Self.open)]).first)
            let view = Self.drawn(item)
            let count = try #require(Self.shownTexts(view).first { $0.stringValue == "1/3" },
                                     "the subagent row draws no 1/3: \(Self.shownTexts(view).map(\.stringValue))")
            #expect(count.frame.width > 0 && count.frame.maxX <= view.bounds.maxX)
            #expect(view.title.frame.maxX <= count.frame.minX, "the title runs under the count")
            #expect((view.accessibilityValue() as? String)?.contains("1 of 3 tasks done") == true,
                    "VoiceOver does not hear the count: \(String(describing: view.accessibilityValue()))")
        }
    }

    @Test func aFinishedListOrNoListShowsNoCount() throws {
        try SidebarTaskProgressTests.withTaskProgress(nil) {
            let items = Self.rows([Self.lane("optchat-sub-6b68ac4a-a2", .idle, list: Self.finished),
                                   Self.lane("optchat-sub-6b68ac4a-a3", .working, list: nil)])
            #expect(items.count == 2)
            for item in items {
                #expect(Self.shownTexts(Self.drawn(item)).allSatisfy { !$0.stringValue.contains("/") })
            }
        }
    }

    @Test func theSettingTurnsItOff() throws {
        try SidebarTaskProgressTests.withTaskProgress(false) {
            let item = try #require(Self.rows([Self.lane("optchat-sub-6b68ac4a-a2", .working, list: Self.open)]).first)
            #expect(Self.shownTexts(Self.drawn(item)).allSatisfy { $0.stringValue != "1/3" })
        }
    }
}
