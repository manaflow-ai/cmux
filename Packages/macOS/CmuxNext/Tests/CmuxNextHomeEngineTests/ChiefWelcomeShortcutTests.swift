import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

struct ChiefWelcomeShortcutTests {
    @Test(arguments: [true, false]) func theStoredWelcomeKeepsTheShortcutsAndExamplesBeforeTheBackgroundOffer(showsTyping: Bool) async throws {
        let text = await ChiefWelcome.text(goTo: "⌘P", shortcuts: [.init(keys: "⇧⌘P", title: "Command Palette"), .init(keys: "⌘T", title: "New Tab")])
        let owner = ChiefWelcomeTests.Owner()
        let welcome = ChiefWelcome(conversation: "conv", owner: owner, showsTyping: showsTyping, text: text)
        try await welcome.play(now: { ChiefWelcomeTests.at }, wait: { await owner.waited($0) })
        let requests = await owner.requests
        let messages = requests.flatMap(\.messages)
        try #require(messages.count == 3)
        #expect(messages.map(\.clientMsgID) == ChiefWelcomeTests.keys)
        #expect(messages[0].parts == [.object(["type": .string("text"), "text": .string(ChiefWelcome.helloText)])])
        #expect(messages[1].parts == [.object(["type": .string("text"), "text": .string(text)])])
        #expect(messages[2].parts == [.object(["type": .string("text"), "text": .string(ChiefWelcome.backgroundText)])])
        if showsTyping {
            #expect(requests.map { $0.messages.count } == [1, 1, 1])
            #expect(await owner.steps.contains(.wait(.seconds(2))))
            #expect(await owner.steps.contains(.wait(.seconds(1))))
        } else {
            #expect(await owner.steps == [.imported(ChiefWelcomeTests.keys), .typing(false)])
        }

        let goTo = try #require(text.range(of: HomeStrings.chiefWelcomeGoTo("⌘P")))
        let palette = try #require(text.range(of: "- `⇧⌘P` Command Palette"))
        let newTab = try #require(text.range(of: "- `⌘T` New Tab"))
        let examples = try #require(text.range(of: HomeStrings.chiefWelcomeExamplesHeader))
        let ask = try #require(text.range(of: HomeStrings.chiefWelcomeAsk))
        #expect(text.hasPrefix(ChiefWelcome.aboutText))
        #expect(text.components(separatedBy: ChiefWelcome.aboutText).count == 2)
        #expect(!text.contains(ChiefWelcome.helloText))
        #expect(goTo.lowerBound < palette.lowerBound && palette.lowerBound < newTab.lowerBound)
        #expect(newTab.lowerBound < examples.lowerBound && examples.lowerBound < ask.lowerBound)
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count == 6)
    }

}
