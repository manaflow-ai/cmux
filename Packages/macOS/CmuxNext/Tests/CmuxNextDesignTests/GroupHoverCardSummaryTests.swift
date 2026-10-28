@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextDesignTokens

/// Lawrence 2026-10-20: "hovering on workspace group or tab group for a while should still show the
/// card, like summary stuff, and should be fully customizable too." One pure summary serves the
/// sidebar's group headers and the tab strip's group chips; its parts and their order follow
/// `GroupHoverCardOptions` (`sidebar.hoverCards.groups.*`).
struct GroupHoverCardSummaryTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let members = [
        GroupHoverCardMember(title: "api", activity: .working, unread: 2, lastActivity: now.addingTimeInterval(-600),
                             branch: "main", ports: ":3000, :5173"),
        GroupHoverCardMember(title: "web", activity: .waiting, lastActivity: now.addingTimeInterval(-120), branch: "feat-ui", ports: ":3000"),
        GroupHoverCardMember(title: "docs", unread: 1, branch: "main"),
    ]

    static func options(_ change: (inout GroupHoverCardOptions) -> Void = { _ in }) -> GroupHoverCardOptions {
        var options = GroupHoverCardOptions()
        change(&options)
        return options
    }

    @Test func theDefaultCardSummarizesStatusMembersActivityBranchesAndPorts() throws {
        let card = GroupHoverCardSummary.make(title: "Agents", kind: .workspaceGroup, members: Self.members, options: Self.options(), now: Self.now)
        #expect(card.title == "Agents")
        #expect(card.blocks.map(\.section) == [.status, .members, .activity, .git, .ports])
        let status = try #require(card.blocks.first)
        #expect(status.lines == ["Working: 1 \u{00B7} Waiting: 1 \u{00B7} Unread: 3"])
        #expect(status.tone == .attention)
        #expect(card.blocks[1].lines == ["Workspaces: 3", "\u{2022} api", "\u{2022} web", "\u{2022} docs"])
        #expect(card.blocks[2].lines == ["Latest: web \u{00B7} 2m"])
        #expect(card.blocks[3].lines == ["Branches: main, feat-ui"])
        #expect(card.blocks[4].lines == ["Ports: :3000, :5173"])
    }

    @Test(arguments: [(GroupHoverCardOptions.Order.members, GroupHoverCardOptions.Section.members),
                      (.activity, .activity), (.status, .status)])
    func theOrderSettingPicksTheLeadingPart(order: GroupHoverCardOptions.Order, lead: GroupHoverCardOptions.Section) {
        let card = GroupHoverCardSummary.make(title: "g", kind: .workspaceGroup, members: Self.members,
                                              options: Self.options { $0.order = order }, now: Self.now)
        #expect(card.blocks.first?.section == lead)
        #expect(Set(card.blocks.map(\.section)).count == 5)
    }

    @Test func turnedOffPartsAreLeftOut() {
        let card = GroupHoverCardSummary.make(title: "g", kind: .workspaceGroup, members: Self.members,
                                              options: Self.options { $0.shown = [.members, .ports] }, now: Self.now)
        #expect(card.blocks.map(\.section) == [.members, .ports])
    }

    @Test func aLongGroupListsMaxMembersThenTheRestAsMore() {
        let many = (1...12).map { GroupHoverCardMember(title: "ws-\($0)") }
        let card = GroupHoverCardSummary.make(title: "big", kind: .tabGroup, members: many,
                                              options: Self.options { $0.shown = [.members]; $0.maxMembers = 3 }, now: Self.now)
        #expect(card.blocks.first?.lines == ["Tabs: 12", "\u{2022} ws-1", "\u{2022} ws-2", "\u{2022} ws-3", "+9 more"])
    }

    @Test func anIdleGroupSaysAllIdleAndSkipsEmptyParts() {
        let idle = [GroupHoverCardMember(title: "a"), GroupHoverCardMember(title: "b")]
        let card = GroupHoverCardSummary.make(title: "quiet", kind: .workspaceGroup, members: idle, options: Self.options(), now: Self.now)
        #expect(card.blocks.map(\.section) == [.status, .members])
        #expect(card.blocks.first?.lines == ["All idle"])
        #expect(card.blocks.first?.tone == .secondary)
    }

    @Test func aFailedMemberTurnsTheStatusRed() {
        let card = GroupHoverCardSummary.make(title: "g", kind: .workspaceGroup,
                                              members: [GroupHoverCardMember(title: "a", activity: .failed), GroupHoverCardMember(title: "b", activity: .working)],
                                              options: Self.options { $0.shown = [.status] }, now: Self.now)
        #expect(card.blocks.first?.lines == ["Working: 1 \u{00B7} Failed: 1"])
        #expect(card.blocks.first?.tone == .danger)
    }

    @Test func statusIndicatorStatesMapToTheCardsCounts() {
        #expect(GroupHoverCardMember.Activity(.idle) == .idle)
        #expect(GroupHoverCardMember.Activity(.success) == .idle)
        #expect(GroupHoverCardMember.Activity(.busy) == .working)
        #expect(GroupHoverCardMember.Activity(.working) == .working)
        #expect(GroupHoverCardMember.Activity(.waiting) == .waiting)
        #expect(GroupHoverCardMember.Activity(.error) == .failed)
    }

    @MainActor @Test func theViewShowsTheSummaryLines() {
        let card = GroupHoverCardSummary.make(title: "Agents", kind: .workspaceGroup, members: Self.members, options: Self.options(), now: Self.now)
        let view = GroupHoverCardView()
        view.configure(card)
        #expect(view.lines == card.lines)
        // A shorter card after a longer one hides the rows it no longer needs.
        let short = GroupHoverCardSummary.make(title: "g", kind: .workspaceGroup, members: Self.members,
                                               options: Self.options { $0.shown = [.status] }, now: Self.now)
        view.configure(short)
        #expect(view.lines == short.lines)
    }
}
