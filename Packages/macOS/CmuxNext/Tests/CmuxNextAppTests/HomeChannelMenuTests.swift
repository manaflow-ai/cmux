import AppKit
import CmuxNextActions
@testable import CmuxNextHomeEngine
import Testing

/// Home's New Channel entry (Chief channels, slice 2): the compose button's menu and the list's
/// background menu offer New Channel… beside New Chief. It runs `home.createChannel`, the palette's,
/// CLI's and MCP's one action; a click names no channel yet, so the palette asks for its name.
@MainActor @Suite struct HomeChannelMenuTests {
    static func registry(asked: @escaping (ActionID) -> Void, ran: @escaping (String?) -> Void) -> ActionRegistry {
        let registry = ActionRegistry(catalog: [
            ActionDescriptor(id: "home.newMessage", title: "New Message", category: .window),
            ActionDescriptor(id: "home.newChief", title: "New Chief…", category: .window),
            ActionDescriptor(id: "home.createChannel", title: "New Channel…", category: .window,
                             arguments: [ActionArgument(name: "title", title: "Channel Name", kind: .string)]),
        ])
        registry.bind("home.newMessage", invoke: { _ in })
        registry.bind("home.newChief", invoke: { _ in })
        registry.bind("home.createChannel", invoke: { invocation in ran(invocation["title"]?.stringValue) })
        registry.argumentCollector = { id, _ in asked(id) }
        return registry
    }

    @Test func theMenuOffersNewChannelAfterNewChief() {
        let registry = Self.registry(asked: { _ in }, ran: { _ in })
        let titles = HomePageMenus.backgroundMenu(registry: registry).items.map(\.title)
        #expect(titles.prefix(3) == ["New Message", "New Chief…", "New Channel…"])
    }

    /// The click has no channel name: the palette asks for it, and the action does not run nameless.
    @Test func aClickAsksThePaletteForTheChannelName() throws {
        var asked: [ActionID] = []
        var ran: [String?] = []
        let registry = Self.registry(asked: { asked.append($0) }, ran: { ran.append($0) })
        let item = try #require(HomePageMenus.backgroundMenu(registry: registry).items.first { $0.title == "New Channel…" })
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        #expect(asked == ["home.createChannel"])
        #expect(ran.isEmpty)
    }
}
