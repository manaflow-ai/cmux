import Foundation
import Testing
@testable import CmuxConversationCore

/// Agent cards (https://github.com/manaflow-ai/cmux/issues/25830): what each
/// card keeps of the agent's input, and the state derived from later messages.
@Suite struct ConversationCardTests {
    private func message(_ id: String, from sender: String, _ text: String, cards: [ConversationCard] = [], unsent: Bool = false) -> ConversationMessage {
        ConversationMessage(
            id: id, seq: nil, clientMessageID: nil, senderID: sender, sentAt: Date(timeIntervalSince1970: 0), text: text,
            unsentAt: unsent ? Date(timeIntervalSince1970: 1) : nil, cards: cards
        )
    }

    @Test func browserCardCleansItsStepAndTarget() throws {
        let card = try #require(ConversationBrowserCard(surface: .browser, step: "  Opening\u{0007} Messaging\n", live: true,
                                                        target: ConversationBrowserCard.Target(wire: "browser:right"),
                                                        url: URL(string: "https://www.linkedin.com/messaging/")))
        #expect(card.step == "Opening Messaging")
        #expect(card.target == .browserRight)
        #expect(card.fallbackText == "Browser: Opening Messaging")
        #expect(ConversationBrowserCard(surface: .browser, step: " \n ") == nil)
        let long = try #require(ConversationBrowserCard(surface: .computer, step: String(repeating: "x", count: 300)))
        #expect(long.step.count == ConversationBrowserCard.maxStepLength)
        #expect(ConversationBrowserCard(surface: .browser, step: "s", url: URL(string: "file:///etc/hosts"))?.url == nil)
    }

    @Test func targetsFollowTheWireRule() {
        #expect(ConversationBrowserCard.Target(wire: "machine:vm_1-A") == .machine("vm_1-A"))
        #expect(ConversationBrowserCard.Target(wire: "machine:vm_1-A")?.wire == "machine:vm_1-A")
        #expect(ConversationBrowserCard.Target(wire: "machine:") == nil)
        #expect(ConversationBrowserCard.Target(wire: "machine:a/b") == nil)
        #expect(ConversationBrowserCard.Target(wire: "machine:" + String(repeating: "a", count: 129)) == nil)
        #expect(ConversationBrowserCard.Target(wire: "browser:left") == nil)
        #expect(ConversationBrowserCard.Target(wire: nil) == nil)
    }

    @Test func signInSitesAreLowercaseDNSNames() throws {
        let card = try #require(ConversationSignInCard(site: "linkedin.com"))
        #expect(card.subtitle == "Sign in to linkedin.com")
        #expect(card.fallbackText == "Secure Store: sign in to linkedin.com")
        #expect(card.addedMessage == "I added my sign-in for linkedin.com to the Secure Store.")
        #expect(card.addOnMacMessage == "I'll add my sign-in for linkedin.com on my Mac.")
        for bad in ["LinkedIn.com", "localhost", "", ".com", "a..b", "a.com.", "a b.com", "a/b.com"] {
            #expect(ConversationSignInCard(site: bad) == nil, "\(bad)")
        }
    }

    @Test func nextStepsKeepThreeDistinctNonEmptyChoices() throws {
        let steps = try #require(ConversationNextSteps(choices: ["  A ", "A", "", "B", "C", "D"]))
        #expect(steps.choices == ["A", "B", "C"])
        #expect(steps.fallbackText == "→ A\n→ B\n→ C")
        #expect(ConversationNextSteps(choices: ["", " "]) == nil)
        let long = try #require(ConversationNextSteps(choices: [String(repeating: "y", count: 200)]))
        #expect(long.choices[0].count == ConversationNextSteps.maxChoiceLength)
    }

    @Test func aChoiceIsChosenWhenALaterMessageOfMineSaysExactlyIt() throws {
        let steps = try #require(ConversationNextSteps(choices: ["Try sending the Kernel update again", "Skip it"]))
        let messages = [
            message("0", from: "me", "Try sending the Kernel update again"),
            message("1", from: "chief", "Done.", cards: [.nextSteps(steps)]),
            message("2", from: "chief", "Try sending the Kernel update again"),
            message("3", from: "me", "try sending the kernel update again"),
            message("4", from: "me", "Skip it", unsent: true),
        ]
        // Before it, from Chief, a different case, or unsent: not chosen.
        #expect(steps.chosen(after: 1, in: messages, meID: "me").isEmpty)
        let chosen = messages + [message("5", from: "me", " Try sending the Kernel update again\n")]
        #expect(steps.chosen(after: 1, in: chosen, meID: "me") == ["Try sending the Kernel update again"])
        #expect(steps.chosen(after: 1, in: chosen, meID: nil).isEmpty)
    }

    @Test func signInReadsAsAddedAfterMyAddedMessage() throws {
        let card = try #require(ConversationSignInCard(site: "linkedin.com"))
        var messages = [message("1", from: "chief", "", cards: [.signIn(card)])]
        #expect(!card.isAdded(after: 0, in: messages, meID: "me"))
        messages.append(message("2", from: "me", card.addOnMacMessage))
        #expect(!card.isAdded(after: 0, in: messages, meID: "me"))
        messages.append(message("3", from: "me", card.addedMessage))
        #expect(card.isAdded(after: 0, in: messages, meID: "me"))
    }

    @Test func messageExposesItsCardsAndTheirText() throws {
        let browser = try #require(ConversationBrowserCard(surface: .browser, step: "Returning to LinkedIn Messaging"))
        let steps = try #require(ConversationNextSteps(choices: ["Go"]))
        let reply = message("1", from: "chief", "Checked.", cards: [.nextSteps(steps)])
        #expect(reply.nextSteps == steps)
        #expect(reply.browserCard == nil)
        #expect(reply.textWithCards == "Checked.\n→ Go")
        let live = message("2", from: "chief", "", cards: [.browser(browser)])
        #expect(live.browserCard == browser)
        #expect(live.textWithCards == "Browser: Returning to LinkedIn Messaging")
        // Editing the card (a new step) changes the message, so the row redraws.
        var edited = live
        edited.cards = [.browser(try #require(ConversationBrowserCard(surface: .browser, step: "Sending")))]
        #expect(edited != live)
    }
}
