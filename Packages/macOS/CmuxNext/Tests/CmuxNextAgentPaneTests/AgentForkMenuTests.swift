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
        #expect(destinations.items.count == 7)
        for item in destinations.items { _ = (item.target as? NSObject)?.perform(item.action) }
        #expect(placed.compactMap { $0["placement"] } == AgentForkDestination.allCases.map(\.rawValue))
        #expect(placed.allSatisfy { $0["throughSeq"] == "42" })
    }
}
