import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

struct ChiefWelcomeShortcutTests {
    @Test(arguments: [true, false]) func theStoredWelcomeKeepsTheShortcutsAndExamplesBeforeTheBackgroundOffer(showsTyping: Bool) async throws {
        let text = ChiefWelcome.text(goTo: "⌘P", shortcuts: [.init(keys: "⇧⌘P", title: "Command Palette"), .init(keys: "⌘T", title: "New Tab")])
        let owner = WelcomeShortcutOwner()
        let keys = [ChiefWelcome.helloClientID, ChiefWelcome.aboutClientID, ChiefWelcome.backgroundClientID]
        let welcome = ChiefWelcome(conversation: "conv", owner: owner, showsTyping: showsTyping, text: text)
        try await welcome.play(now: { Date(timeIntervalSince1970: 1_793_404_800.25) }, wait: { await owner.waited($0) })
        let requests = await owner.requests
        let messages = requests.flatMap(\.messages)
        try #require(messages.count == 3)
        #expect(messages.map(\.clientMsgID) == keys)
        #expect(messages[0].parts == [.object(["type": .string("text"), "text": .string(ChiefWelcome.helloText)])])
        #expect(messages[1].parts == [.object(["type": .string("text"), "text": .string(text)])])
        #expect(messages[2].parts == [.object(["type": .string("text"), "text": .string(ChiefWelcome.backgroundText)])])
        if showsTyping {
            #expect(requests.map { $0.messages.count } == [1, 1, 1])
            #expect(await owner.steps.contains(.wait(.seconds(2))))
            #expect(await owner.steps.contains(.wait(.seconds(1))))
        } else {
            #expect(await owner.steps == [.imported(keys), .typing(false)])
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

private actor WelcomeShortcutOwner: ChiefWelcomeOwner {
    enum Step: Equatable {
        case wait(Duration)
        case typing(Bool)
        case imported([String])
    }

    var steps: [Step] = []
    var requests: [ConversationImportRequest] = []

    func showChiefTyping(_ on: Bool) { steps.append(.typing(on)) }

    func importWelcome(_ request: ConversationImportRequest) {
        steps.append(.imported(request.messages.map(\.clientMsgID)))
        requests.append(request)
    }

    func waited(_ pause: Duration) { steps.append(.wait(pause)) }
}
