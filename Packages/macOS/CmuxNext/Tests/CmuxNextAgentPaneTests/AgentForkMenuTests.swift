import AppKit
import Testing
@testable import CmuxNextAgentPane

@MainActor @Suite struct AgentForkMenuTests {
    @Test func rightClickForksImmediatelyAndOffersAllDestinationsSeparately() throws {
        var forked: [Int] = []
        var placed: [[String: String]] = []
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: .init(text: "Hello", forkSeq: 42), devTools: false,
            actions: .init(copy: { _ in }, fork: { forked.append($0) }, page: { name, params in
                #expect(name == "chat.fork")
                placed.append(params)
            }))
        let primary = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.forkFromHere })
        #expect(primary.submenu == nil)
        _ = (primary.target as? NSObject)?.perform(primary.action)
        #expect(forked == [42])
        let destinations = try #require(menu.items.first { $0.title == AgentForkMenu.title }?.submenu)
        let rows = destinations.items.filter { !$0.isSeparatorItem }
        #expect(rows.count == AgentForkDestination.allCases.count)
        for item in rows { _ = (item.target as? NSObject)?.perform(item.action) }
        #expect(placed.compactMap { $0["placement"] } == AgentForkDestination.allCases.map(\.rawValue))
        #expect(placed.allSatisfy { $0["throughSeq"] == "42" })
    }

    /// u18673: Fork to… offers a new column on either side and a new row, and keeps the ten rows
    /// short by grouping them: splits, then strip columns and rows, then tab, workspace and window.
    @Test func forkToGroupsSplitsStripAndElsewhereBetweenSeparators() {
        let menu = AgentForkMenu.menu { _ in }
        var groups: [[String]] = [[]]
        for item in menu.items {
            if item.isSeparatorItem { groups.append([]) } else { groups[groups.count - 1].append(item.title) }
        }
        let ids = AgentForkMenu.groups.map { $0.map(\.rawValue) }
        #expect(ids == [["right", "left", "up", "down"], ["columnRight", "columnLeft", "row"], ["tab", "workspace", "window"]])
        #expect(groups.map(\.count) == [4, 3, 3])
    }

    /// The new destinations name a strip column or a row, never a split direction.
    @Test func columnAndRowDestinationsAreNotSplits() {
        #expect(AgentForkDestination(placement: "columnRight") == .columnRight)
        #expect(AgentForkDestination(placement: "columnLeft") == .columnLeft)
        #expect(AgentForkDestination(placement: "row") == .row)
        for destination in [AgentForkDestination.columnRight, .columnLeft, .row] {
            #expect(destination.splitDirection == nil)
        }
    }

    /// Quote in Reply on a whole message (not only on selected text): the message goes into the
    /// composer as a quote, appended to the draft (`chat.quoteReply`), never through Edit and Resend's
    /// `chat.editPrompt`, which would replace what the person typed.
    @Test func aMessageOffersQuoteInReplyWithoutASelection() throws {
        var edited: [String] = []
        var quoted: [String] = []
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: .init(text: "Two\nlines", forkSeq: 3), devTools: false,
            actions: .init(copy: { _ in }, fork: { _ in }, edit: { edited.append($0) }, quoteReply: { quoted.append($0) }, page: { _, _ in }))
        let quote = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.quoteInReply })
        _ = (quote.target as? NSObject)?.perform(quote.action)
        #expect(quoted == [AgentPaneContextMenu.quote("Two\nlines")])
        #expect(edited.isEmpty)
    }
}
