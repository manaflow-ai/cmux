import CmuxNextAgentPane
import AppKit
@testable import CmuxNextApp
import Testing

@Suite("Right pane placement")
struct RightPanePlacementTests {
    private typealias Policy = RightPanePlacement

    @Test func noRightColumnCreatesOne() {
        #expect(Policy.decide(kind: .documents, identity: "diff", chatWidth: 720, rightColumnWidth: 0) == .createRightColumn)
    }

    @Test func existingDocumentsInsertAfterActiveTopTab() {
        let docs = Policy.Area(tabs: [.init(id: "a"), .init(id: "b")], active: "a")
        #expect(Policy.decide(kind: .documents, identity: "diff", chatWidth: 720, rightColumnWidth: 520, documents: docs) == .openTab(kind: .documents, anchor: "a"))
    }

    @Test func missingActiveFallsBackToLastTab() {
        let docs = Policy.Area(tabs: [.init(id: "a"), .init(id: "b")], active: "gone")
        #expect(Policy.decide(kind: .documents, identity: "diff", chatWidth: 720, rightColumnWidth: 520, documents: docs) == .openTab(kind: .documents, anchor: "b"))
    }

    @Test func firstSessionSplitsBelowDocuments() {
        let docs = Policy.Area(tabs: [.init(id: "diff")], active: "diff")
        #expect(Policy.decide(kind: .session, identity: "child", chatWidth: 720, rightColumnWidth: 520, documents: docs) == .splitSessionsBelowDocuments)
    }

    @Test func firstSessionStillSplitsWhenTopAreaIsEmpty() {
        #expect(Policy.decide(kind: .session, identity: "child", chatWidth: 720, rightColumnWidth: 520) == .splitSessionsBelowDocuments)
    }

    @Test func laterSessionsStayInBottomArea() {
        let docs = Policy.Area(tabs: [.init(id: "diff")], active: "diff")
        let sessions = Policy.Area(tabs: [.init(id: "one")], active: "one")
        #expect(Policy.decide(kind: .session, identity: "two", chatWidth: 720, rightColumnWidth: 520, documents: docs, sessions: sessions) == .openTab(kind: .session, anchor: "one"))
    }

    @Test func deduplicatesAnywhereInRightColumn() {
        let docs = Policy.Area(tabs: [.init(id: "diff")], active: "diff")
        let sessions = Policy.Area(tabs: [.init(id: "child")], active: "child")
        #expect(Policy.decide(kind: .documents, identity: "child", chatWidth: 720, rightColumnWidth: 520, documents: docs, sessions: sessions) == .selectExisting("child"))
    }

    @Test func narrowChatDoesNotSplit() {
        #expect(Policy.decide(kind: .documents, identity: "diff", chatWidth: 479, rightColumnWidth: 0) == .openInChat)
        let docs = Policy.Area(tabs: [.init(id: "existing")], active: "existing")
        #expect(Policy.decide(kind: .session, identity: "child", chatWidth: 479, rightColumnWidth: 520, documents: docs) == .openTabWithoutSplit(kind: .session, anchor: nil))
    }

    @Test func narrowRightColumnDoesNotSplit() {
        let docs = Policy.Area(tabs: [.init(id: "existing")], active: "existing")
        #expect(Policy.decide(kind: .session, identity: "child", chatWidth: 720, rightColumnWidth: 419, documents: docs) == .openTabWithoutSplit(kind: .session, anchor: nil))
    }
}
