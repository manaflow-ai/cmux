import AppKit
import CmuxHomeCore
import CmuxNextDesign
import CmuxNextIcons
import Testing
@testable import CmuxNextHome

/// Home's first-run rows and the Conversations add button draw from the cmux
/// icon registry at the size of the text beside them.
@MainActor @Suite struct HomeRegistryIconTests {
    @Test func firstRunRowsNameTheirRegistryIcon() {
        let view = HomeFirstRunView()
        #expect(view.terminal.icon == .terminalNew)
        #expect(view.agent.icon == .agentChat)
        #expect(view.suggestion.icon == .agentQuestion)
    }

    @Test func aFirstRunGlyphIsRowSizeAndFollowsTheScale() throws {
        let row = HomeFirstRunRow(title: "Open a terminal", icon: .terminalNew)
        let side = CGFloat.iconRowSize(forLabelPointSize: 13)
        let image = try #require(row.glyph.image)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: side, height: side))
        row.applyScale(1.5)
        #expect(row.glyph.image?.size == NSSize(width: CGFloat.iconRowSize(forLabelPointSize: 19.5), height: CGFloat.iconRowSize(forLabelPointSize: 19.5)))
    }

    /// The add glyph fills a full icon box: the pack's plus at the header's
    /// row size draws 7 px of ink where the SF plus it replaced drew 10.
    @Test func theAddButtonIsTheRegistryAdd() throws {
        let list = HomeConversationListView(frame: .zero)
        let image = try #require(list.addButtonImage)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: Metrics.iconSize, height: Metrics.iconSize))
    }

    @Test func chiefConversationRowsUseTheRegistryMarkAndKeepTheirChromeBreathingRoom() throws {
        let me = Participant(id: ParticipantID("me"), kind: .human, displayName: "Me")
        let chief = Participant(id: ParticipantID("chief"), kind: .agent, displayName: "Chief", agentClass: .chief,
                                ownerUser: ParticipantID("me"))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let summary = ConversationSummary(id: ConversationID("chief"), title: "Chief", participants: [me, chief],
                                          lastSeq: Seq(1), createdAt: now, updatedAt: now)
        let row = InboxRow(summary: summary, kind: .chief, title: "Chief", preview: "Worked for 3s",
                           previewAttachments: nil, previewAuthor: nil, timestamp: now, unread: 0, mentions: 0,
                           isPinned: false, isSending: false, hasFailedSend: false, isTyping: false)
        let cell = HomeConversationCellView(frame: NSRect(x: 0, y: 0, width: 320, height: HomeConversationCellView.height))
        cell.show(row, me: me.id)
        cell.layoutSubtreeIfNeeded()

        let icon = try #require(cell.avatarGlyph.image)
        #expect(icon.isTemplate)
        #expect(icon.size == NSSize(width: Metrics.iconSize, height: Metrics.iconSize))
        #expect(cell.avatar.isHidden)
        #expect(cell.highlightFrame.maxY <= cell.bounds.height - Metrics.space1)
        #expect(cell.time.lineBreakMode == .byClipping)
        #expect(HomeConversationTableRowView().drawsSeparator == false)
    }
}
