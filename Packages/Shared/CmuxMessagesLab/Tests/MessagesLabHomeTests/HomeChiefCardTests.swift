import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A Chief's cards (cmux issue 25830): the live browser card, the Secure Store sign-in card and the
/// next-step chips, as drawn rows in the Home chat, their clicks, and the state they derive.
@Suite(.serialized) @MainActor struct HomeChiefCardTests {
    static let t = HomeChatRig.tag
    static let browser = ChiefCard.browser(step: "Returning to LinkedIn Messaging", live: true, target: "browser:right",
                                           url: "https://www.linkedin.com/messaging/",
                                           image: ChiefCard.Image(hash: String(repeating: "a", count: 64), mimeType: "image/png",
                                                                  byteCount: 1234, width: 1280, height: 800))
    static let signIn = ChiefCard.signIn(site: "linkedin.com", url: "https://www.linkedin.com/login")
    static let steps = ChiefCard.nextSteps(["\(t)Try sending the Kernel update again", "\(t)Check the Nov 4 event thread"])

    init() {
        HomeMarkdownPolicy.install()
        HomeChiefCardRowProvider.install()
    }

    static func payload(_ part: Part) -> HomeChiefCardRowProvider.Payload? {
        guard case let .custom(c) = part else { return nil }
        return HomeChiefCardRowProvider.payload(c)
    }

    // MARK: Mapping

    @Test func eachKindIsADrawnRowInAnIncomingBubble() throws {
        for card in [Self.browser, Self.signIn, Self.steps] {
            let part = HomeMapping.part(.card(card))
            guard case let .custom(c) = part else { Issue.record("\(card.kind) is no drawn row: \(part)"); continue }
            #expect(c.kind == HomeChiefCardRowProvider.kind)
            #expect(HomeChiefCardRowProvider.payload(c)?.card == card)
            #expect(HomeChiefCardRowProvider().layout(for: c) == .bubbleIncoming)
        }
    }

    @Test func aCardIsOnePartAfterTheReplyText() {
        let item = TranscriptItem(key: IdempotencyKey("reply"), seq: 9, author: ParticipantID("agent_chief"),
                                  parts: [.text("Done."), .card(Self.steps)], createdAt: Date(), delivery: .committed)
        let (parts, owners) = HomeMapping.projectedParts(item, summary: nil)
        #expect(owners == [0, 1])
        #expect(Self.payload(parts[1])?.card.kind == .nextSteps)
    }

    @Test func theScreenshotFillsInOnceItsPictureIsReady() {
        let hash = Self.browser.image?.hash ?? ""
        let before = Self.payload(HomeChiefCardRowProvider.part(Self.browser, media: { _ in nil }, context: HomeChiefCardContext()))
        let after = Self.payload(HomeChiefCardRowProvider.part(Self.browser, media: { $0 == hash ? "file:///tmp/shot.png" : nil },
                                                                 context: HomeChiefCardContext()))
        #expect(before?.picture == nil)
        #expect(after?.picture == "file:///tmp/shot.png")
    }

    @Test func aNewStepIsANewVersion() throws {
        var next = Self.browser
        next.step = "Opening the Kernel thread"
        guard case let .custom(a) = HomeMapping.part(.card(Self.browser)), case let .custom(b) = HomeMapping.part(.card(next)) else {
            Issue.record("no drawn rows")
            return
        }
        #expect(a.version != b.version, "a changed card redraws (the row bitmap and the measure cache key on the version)")
    }

    @Test func signInShowsAddedWhenTheSecureStoreHoldsTheSite() {
        #expect(Self.payload(HomeMapping.part(.card(Self.signIn)))?.added == false)
        let stored = HomeChiefCardRowProvider.part(Self.signIn, media: { _ in nil }, context: HomeChiefCardContext(stored: ["linkedin.com"]))
        #expect(Self.payload(stored)?.added == true)
        let state = HomeChiefCardState()
        state.setStoredSites(["LinkedIn.com"])
        #expect(state.storedSites == ["linkedin.com"], "the state keeps sites lowercased")
    }

    /// As `ChiefSecureStore.credential(forHost:)` matches: a saved parent domain covers the card's host.
    @Test func signInShowsAddedWhenAParentDomainIsSaved() {
        let context = HomeChiefCardContext(stored: ["linkedin.com"])
        #expect(context.holds("www.linkedin.com"))
        #expect(context.holds("LinkedIn.com."))
        #expect(!context.holds("evillinkedin.com"), "a suffix that is not a parent domain")
        #expect(!context.holds("com"))
        #expect(!HomeChiefCardContext(stored: ["www.linkedin.com"]).holds("linkedin.com"), "a child site does not cover its parent")
        var card = Self.signIn
        card.site = "www.linkedin.com"
        let part = HomeChiefCardRowProvider.part(card, media: { _ in nil }, context: context)
        #expect(Self.payload(part)?.added == true)
    }

    // MARK: Clicks (the layout the drawing used)

    @Test func openBrowserIsTheBottomButton() throws {
        let payload = try #require(Self.payload(HomeMapping.part(.card(Self.browser))))
        let layout = HomeChiefCardLayout(payload, width: 400)
        let button = try #require(layout.button)
        #expect(layout.picture != nil, "the screenshot inset sits above the button")
        #expect(layout.action(at: CGPoint(x: button.midX, y: button.midY)) == .open(.browserRight, url: "https://www.linkedin.com/messaging/"))
        #expect(layout.action(at: CGPoint(x: 20, y: 20)) == nil, "the header is no button")
        #expect(button.maxY < layout.height)
    }

    @Test func aBrowserCardWithoutATargetHasNoButton() throws {
        var card = Self.browser
        card.target = nil
        let payload = try #require(Self.payload(HomeMapping.part(.card(card))))
        #expect(HomeChiefCardLayout(payload, width: 400).button == nil)
    }

    @Test func aMachineTargetOpensItsDesktop() throws {
        var card = Self.browser
        card.surface = .computer
        card.target = "machine:vm_123-abc"
        let payload = try #require(Self.payload(HomeMapping.part(.card(card))))
        let layout = HomeChiefCardLayout(payload, width: 400)
        let button = try #require(layout.button)
        #expect(layout.action(at: CGPoint(x: button.midX, y: button.midY)) == .open(.machine("vm_123-abc"), url: card.url))
        #expect(HomeChiefCards.text(payload).contains(CmuxStrings.chiefCardOpenDesktop))
    }

    @Test func addIsOfferedUntilTheSiteIsStored() throws {
        var payload = try #require(Self.payload(HomeMapping.part(.card(Self.signIn))))
        let button = try #require(HomeChiefCardLayout(payload, width: 300).button)
        let center = CGPoint(x: button.midX, y: button.midY)
        #expect(HomeChiefCardLayout(payload, width: 300).action(at: center) == .addSignIn(site: "linkedin.com", url: "https://www.linkedin.com/login"))
        payload.added = true
        #expect(HomeChiefCardLayout(payload, width: 300).action(at: center) == nil, "Added is disabled")
    }

    @Test func eachChipSendsItsChoiceUntilChosen() throws {
        var payload = try #require(Self.payload(HomeMapping.part(.card(Self.steps))))
        let layout = HomeChiefCardLayout(payload, width: 400)
        #expect(layout.chips.count == 2)
        for (chip, choice) in zip(layout.chips, Self.steps.choices) {
            #expect(layout.action(at: CGPoint(x: chip.frame.midX, y: chip.frame.midY)) == .choose(choice))
            #expect(abs(chip.frame.width - (400 - 2 * HomeChiefCardLayout.chipInset)) < 0.5, "a chip is the card's full width")
        }
        payload.chosen = [Self.steps.choices[0]]
        let chosen = HomeChiefCardLayout(payload, width: 400)
        #expect(chosen.action(at: CGPoint(x: chosen.chips[0].frame.midX, y: chosen.chips[0].frame.midY)) == nil, "a chosen chip is disabled")
        #expect(chosen.action(at: CGPoint(x: chosen.chips[1].frame.midX, y: chosen.chips[1].frame.midY)) == .choose(Self.steps.choices[1]))
    }

    // MARK: Derived state

    @Test func aChipIsChosenByALaterPersonMessageWithItsText() {
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        func item(_ key: String, _ author: ParticipantID, _ parts: [MessagePart]) -> TranscriptItem {
            TranscriptItem(key: IdempotencyKey(key), seq: nil, author: author, parts: parts, createdAt: Date(), delivery: .committed)
        }
        let choice = Self.steps.choices[1]
        let items = [
            item("before", me, [.text(Self.steps.choices[0])]),
            item("card", chief, [.text("Done."), .card(Self.steps)]),
            item("chief", chief, [.text(Self.steps.choices[0])]),
            item("after", me, [.text("  \(choice)\n")]),
        ]
        let chosen = HomeChiefCards.chosen(in: items) { $0 == me }
        // Only a person's later message counts: not one before the card, not the Chief's own.
        #expect(chosen == [IdempotencyKey("card"): [choice]])
    }

    @Test func theAddedMessageNamesTheSite() {
        #expect(HomeChiefCards.signInAddedMessage("linkedin.com") == "I added my sign-in for linkedin.com to the Secure Store.")
    }

    // MARK: The real view

    @Test func aChipClickSendsItsTextAndThenShowsChosen() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        #expect(await rig.post([.text("\(Self.t)Done."), .card(Self.steps)], key: IdempotencyKey("reply")))
        rig.frame()
        let choice = Self.steps.choices[0]
        rig.view.projection.chiefCardAction(.choose(choice), at: MessagesLabHome.PartRef(messageId: "reply", partIndex: 1))
        await HomeChatRig.until { [store = rig.store] in
            store.transcript(for: HomeChatRig.conversation).contains { $0.author == rig.me && $0.plainText == choice && $0.seq != nil }
        }
        rig.frame()
        let cards = rig.view.controller.store?.state.conversation.messages.flatMap(\.parts).compactMap(Self.payload) ?? []
        #expect(cards.map(\.chosen) == [[choice]], "the chip a person message said shows chosen")
    }

    @Test func aSavedSignInSendsTheAddedMessage() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        #expect(await rig.post([.card(Self.signIn)], key: IdempotencyKey("signin")))
        rig.frame()
        let state = HomeChiefCardState()
        rig.view.chiefCardState = state
        var asked: [String] = []
        rig.view.onChiefSignIn = { site, _, done in
            asked.append(site)
            state.addStoredSite(site)
            done(true)
        }
        rig.view.projection.chiefCardAction(.addSignIn(site: "linkedin.com", url: nil), at: MessagesLabHome.PartRef(messageId: "signin", partIndex: 0))
        let text = HomeChiefCards.signInAddedMessage("linkedin.com")
        await HomeChatRig.until { [store = rig.store] in
            store.transcript(for: HomeChatRig.conversation).contains { $0.author == rig.me && $0.plainText == text }
        }
        rig.frame()
        #expect(asked == ["linkedin.com"])
        #expect(rig.store.transcript(for: HomeChatRig.conversation).contains { $0.author == rig.me && $0.plainText == text })
        let cards = rig.view.controller.store?.state.conversation.messages.flatMap(\.parts).compactMap(Self.payload) ?? []
        #expect(cards.map(\.added) == [true], "the card shows Added")
    }

    @Test func aCancelledSignInSendsNothing() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        #expect(await rig.post([.card(Self.signIn)], key: IdempotencyKey("signin")))
        rig.frame()
        rig.view.onChiefSignIn = { _, _, done in done(false) }
        let before = rig.store.transcript(for: HomeChatRig.conversation).count
        rig.view.projection.chiefCardAction(.addSignIn(site: "linkedin.com", url: nil), at: MessagesLabHome.PartRef(messageId: "signin", partIndex: 0))
        rig.frame()
        #expect(rig.store.transcript(for: HomeChatRig.conversation).count == before)
    }

    @Test func aLiveEditUpdatesTheCardInPlace() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        #expect(await rig.post([.card(Self.browser)], key: IdempotencyKey("live")))
        rig.frame()
        let rebuilds = rig.view.projection.rebuilds
        var next = Self.browser
        next.step = "Opening the Kernel thread"
        let edited = await rig.source.edit(key: IdempotencyKey("live"), in: HomeChatRig.conversation, parts: [.card(next)])
        #expect(edited)
        await HomeChatRig.until { [store = rig.store] in
            store.transcript(for: HomeChatRig.conversation).contains { $0.key == IdempotencyKey("live") && $0.parts == [.card(next)] }
        }
        rig.frame()
        let cards = rig.view.controller.store?.state.conversation.messages.flatMap(\.parts).compactMap(Self.payload) ?? []
        #expect(cards.map(\.card.step) == ["Opening the Kernel thread"])
        #expect(rig.view.projection.rebuilds == rebuilds, "an edited card is replaced in place, not by a rebuild")
    }
}
