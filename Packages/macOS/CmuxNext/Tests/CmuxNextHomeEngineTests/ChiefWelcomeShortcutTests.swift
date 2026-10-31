import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

struct ChiefWelcomeShortcutTests {
    @Test func theStoredWelcomeKeepsTheShortcutsAndExamplesBeforeTheBackgroundOffer() async throws {
        let text = ChiefWelcome.text(goTo: "⌘P", shortcuts: [.init(keys: "⇧⌘P", title: "Command Palette"), .init(keys: "⌘T", title: "New Tab")])
        let owner = ChiefWelcomeTests.Owner()
        let welcome = ChiefWelcome(conversation: "conv", owner: owner, showsTyping: true, text: text)
        #expect(await welcome.start() == .milliseconds(1500))
        try await welcome.deliver(now: ChiefWelcomeTests.at)
        let request = try #require(await owner.requests.first)
        #expect(request.messages.map(\.clientMsgID) == ChiefWelcomeTests.keys)
        #expect(request.messages[0].parts == [.object(["type": .string("text"), "text": .string(text)])])
        #expect(request.messages[1].parts == [.object(["type": .string("text"), "text": .string(ChiefWelcome.backgroundText)])])
        #expect(await owner.steps == [.typing(true), .imported(ChiefWelcomeTests.keys), .typing(false)])

        let goTo = try #require(text.range(of: HomeStrings.chiefWelcomeGoTo("⌘P")))
        let palette = try #require(text.range(of: "- `⇧⌘P` Command Palette"))
        let newTab = try #require(text.range(of: "- `⌘T` New Tab"))
        let examples = try #require(text.range(of: HomeStrings.chiefWelcomeExamplesHeader))
        let ask = try #require(text.range(of: HomeStrings.chiefWelcomeAsk))
        #expect(text.hasPrefix(ChiefWelcome.welcomeText))
        #expect(text.components(separatedBy: ChiefWelcome.welcomeText).count == 2)
        #expect(goTo.lowerBound < palette.lowerBound && palette.lowerBound < newTab.lowerBound)
        #expect(newTab.lowerBound < examples.lowerBound && examples.lowerBound < ask.lowerBound)
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count == 6)
    }

}
