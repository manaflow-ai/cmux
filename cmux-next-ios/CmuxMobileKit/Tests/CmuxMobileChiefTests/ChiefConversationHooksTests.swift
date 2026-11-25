import Foundation
import Testing
@testable import CmuxConversationCore
@testable import CmuxMobileChief
#if canImport(UIKit)
import UIKit
@testable import CmuxConversationUI

/// The Chief zoom (Zoom In, Zoom Out, Actual Size: the Mac's `home.zoomIn`,
/// `home.zoomOut`, `home.zoomReset`), saved on the phone.
@MainActor
@Suite final class ChiefTextZoomTests {
    /// Each test's own defaults suite, removed when the suite's test ends.
    private final class Suite {
        let name = "chief-zoom-\(UUID().uuidString)"
        let defaults: UserDefaults
        init() throws { defaults = try #require(UserDefaults(suiteName: name)) }
        deinit { defaults.removePersistentDomain(forName: name) }
    }
    private var suites: [Suite] = []

    private func zoom() throws -> (ChiefTextZoom, UserDefaults) {
        let suite = try Suite()
        suites.append(suite)
        return (ChiefTextZoom(defaults: suite.defaults), suite.defaults)
    }

    @Test func zoomStepsDynamicTypeSizesFromThePersonsOwnAndIsSaved() throws {
        let (zoom, defaults) = try self.zoom()
        #expect(zoom.textSize(system: .large) == nil)
        #expect(zoom.percent(system: .large) == 100)
        zoom.zoomIn(system: .large)
        zoom.zoomIn(system: .large)
        #expect(zoom.textSize(system: .large) == .extraExtraLarge)
        #expect(zoom.percent(system: .large) == 124)
        #expect(ChiefTextZoom(defaults: defaults).step == 2)
        zoom.zoomOut(system: .large)
        #expect(zoom.textSize(system: .large) == .extraLarge)
        zoom.actualSize()
        #expect(zoom.textSize(system: .large) == nil)
        #expect(ChiefTextZoom(defaults: defaults).step == 0)
        #expect(defaults.object(forKey: ChiefTextZoom.defaultsKey) == nil)
    }

    @Test func zoomStopsAtTheSmallestAndLargestSizes() throws {
        let (zoom, _) = try self.zoom()
        #expect(zoom.canZoomOut(system: .extraSmall) == false)
        zoom.zoomOut(system: .extraSmall)
        #expect(zoom.step == 0)
        let (top, _) = try self.zoom()
        #expect(!top.canZoomIn(system: .accessibilityExtraExtraExtraLarge))
        top.zoomOut(system: .accessibilityExtraExtraExtraLarge)
        #expect(top.textSize(system: .accessibilityExtraExtraExtraLarge) == .accessibilityExtraExtraLarge)
        #expect(top.canZoomIn(system: .accessibilityExtraExtraExtraLarge))
    }

    /// A zoom saved at a smaller system size that now reaches past the largest:
    /// Zoom Out moves the text at once instead of spending taps past the end.
    @Test func aStepPastTheEndCountsFromWhereItStops() throws {
        let (zoom, _) = try self.zoom()
        for _ in 0..<6 { zoom.zoomIn(system: .large) }
        #expect(zoom.step == 6)
        let system = ConversationTextSize.accessibilityExtraLarge
        #expect(zoom.textSize(system: system) == .accessibilityExtraExtraExtraLarge)
        #expect(!zoom.canZoomIn(system: system))
        zoom.zoomOut(system: system)
        #expect(zoom.textSize(system: system) == .accessibilityExtraExtraLarge)
    }

    @Test func menuTitlesAreTheMacs() {
        #expect(ChiefPageMenu.zoomInTitle == "Zoom In")
        #expect(ChiefPageMenu.zoomOutTitle == "Zoom Out")
        #expect(ChiefPageMenu.actualSizeTitle == "Actual Size")
        #expect(ChiefPageMenu.title == "More")
        #expect(ChiefPageMenu.textSizeTitle(percent: 112).hasPrefix("Text Size: 112"))
    }
}

/// CmuxConversation's host hooks as the Chief screen uses them: Reply with
/// Selection, the host text size and the header's page menu.
@MainActor
@Suite(.serialized)
struct ChiefConversationHooksTests {
    private func loaded(_ messages: [ConversationMessage]) async throws -> (ConversationViewController, UIWindow) {
        let store = ConversationStore(backend: HooksBackend(messages: messages))
        let controller = ConversationViewController(store: store, options: .chief)
        let (loaded, continuation) = AsyncStream<Void>.makeStream()
        store.addObserver { change in
            if change == .reset { continuation.yield(()); continuation.finish() }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        // A window without a scene sends no appearance calls: UIKit's own transition does.
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        store.apply(.connected(info: .init(id: "chief", title: "Chief", kind: .group, participants: []), meID: "me", lagged: false))
        var pages = loaded.makeAsyncIterator()
        _ = await pages.next()
        try #require(store.hasLoadedNewest)
        controller.view.layoutIfNeeded()
        controller.collectionView.layoutIfNeeded()
        return (controller, window)
    }

    private static func message(_ id: String, _ text: String, seq: Int) -> ConversationMessage {
        ConversationMessage(id: id, seq: seq, clientMessageID: nil, senderID: "chief", sentAt: Date(), text: text)
    }

    @Test(.timeLimit(.minutes(1))) func replyWithSelectionHandsTheHostTheSelectedWordsAndOpensTheReply() async throws {
        let source = Self.message("m1", "Deploy the build, then run the tests.", seq: 1)
        let (controller, window) = try await loaded([source])
        defer { ConversationThemeOwners.disappeared(controller); controller.store.stop(); window.isHidden = true }
        var replies: [ConversationSelectionReply] = []
        controller.onReplyWithSelection = { [weak controller] reply in
            replies.append(reply)
            if let controller { ChiefPageMenu.replyWithSelection(reply, in: controller) }
        }
        controller.composer.text = "and tell me"
        controller.beginTextSelection(rowID: source.rowID)
        let selection = try #require(controller.textSelection)
        // The menu leads with Reply with Selection, then the system's own actions.
        // UITextView keeps its own edit menu interactions; the selection adds one it delegates.
        let editMenus = selection.interactions.compactMap { $0 as? UIEditMenuInteraction }
        let interaction = try #require(editMenus.first { $0.delegate === selection })
        let copy = UIAction(title: "Copy") { _ in }
        let menu = selection.editMenuInteraction(interaction, menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero),
                                                 suggestedActions: [copy])
        #expect(menu?.children.map { ($0 as? UIAction)?.title } == ["Reply with Selection", "Copy"])
        selection.selectedRange = ("Deploy the build, then run the tests." as NSString).range(of: " then run the tests")
        #expect(selection.replyWithSelection())
        #expect(replies == [ConversationSelectionReply(messageID: "m1", text: "then run the tests")])
        #expect(controller.textSelection == nil)
        #expect(controller.replyTarget?.id == "m1")
        #expect(controller.composer.text == "> then run the tests\n\nand tell me")
        controller.exitReplyMode()
    }

    @Test(.timeLimit(.minutes(1))) func withoutTheHookTheSelectionMenuIsTheSystemsAlone() async throws {
        let source = Self.message("m1", "Only the system menu here.", seq: 1)
        let (controller, window) = try await loaded([source])
        defer { ConversationThemeOwners.disappeared(controller); controller.store.stop(); window.isHidden = true }
        controller.beginTextSelection(rowID: source.rowID)
        let selection = try #require(controller.textSelection)
        let editMenus = selection.interactions.compactMap { $0 as? UIEditMenuInteraction }
        #expect(!editMenus.isEmpty)
        #expect(!editMenus.contains { $0.delegate === selection })
        #expect(selection.textView(selection, editMenuForTextIn: selection.selectedRange, suggestedActions: []) == nil)
        #expect(!selection.replyWithSelection())
        controller.endTextSelection()
        #expect(!controller.beginReply(toMessageID: "missing"))
    }

    @Test(.timeLimit(.minutes(1))) func textSizeRedrawsTheTranscriptAtThatSizeAndNilFollowsTheSystem() async throws {
        let (controller, window) = try await loaded([Self.message("m1", "Some text", seq: 1)])
        defer {
            controller.textSize = nil
            ConversationThemeOwners.disappeared(controller)
            controller.store.stop(); window.isHidden = true
        }
        let system = ConversationTheme.bubbleFont.pointSize
        #expect(ConversationTheme.textSizeTraits == nil)
        controller.textSize = .accessibilityMedium
        controller.view.layoutIfNeeded()
        #expect(controller.traitCollection.preferredContentSizeCategory == .accessibilityMedium)
        #expect(ConversationTheme.bubbleFont.pointSize == 28)
        #expect(controller.composer.textView.font?.pointSize == 28)
        controller.textSize = .extraSmall
        controller.view.layoutIfNeeded()
        #expect(ConversationTheme.bubbleFont.pointSize == 14)
        controller.textSize = nil
        controller.view.layoutIfNeeded()
        #expect(ConversationTheme.textSizeTraits == nil)
        #expect(ConversationTheme.bubbleFont.pointSize == system)
    }

    @Test(.timeLimit(.minutes(1))) func headerMenuOpensFromTheTrailingButtonOnlyInTheNormalState() async throws {
        let (controller, window) = try await loaded([])
        defer { ConversationThemeOwners.disappeared(controller); controller.store.stop(); window.isHidden = true }
        let button = controller.header.trailingButton
        #expect(button.menu == nil && !button.showsMenuAsPrimaryAction)
        let menu = UIMenu(children: [UIAction(title: "Invite to cmux") { _ in }])
        controller.headerActionMenu = menu
        // The button keeps a copy of the menu: compare by identifier.
        #expect(button.menu?.identifier == menu.identifier && button.showsMenuAsPrimaryAction)
        controller.setSelecting(true)
        #expect(button.menu == nil && !button.showsMenuAsPrimaryAction)
        controller.setSelecting(false)
        #expect(button.menu?.identifier == menu.identifier)
        controller.headerActionMenu = nil
        #expect(button.menu == nil && !button.showsMenuAsPrimaryAction)
    }

    @Test(.timeLimit(.minutes(1))) func editModeKeepsTheTrailingTapForEndingTheEdit() async throws {
        let source = ConversationMessage(id: "m1", seq: 1, clientMessageID: nil, senderID: "me", sentAt: Date(), text: "Mine to edit")
        let (controller, window) = try await loaded([source])
        defer { ConversationThemeOwners.disappeared(controller); controller.store.stop(); window.isHidden = true }
        let menu = UIMenu(children: [UIAction(title: "Invite to cmux") { _ in }])
        controller.headerActionMenu = menu
        controller.enterEditMode(for: source)
        try #require(controller.editingMessageID == "m1")
        #expect(controller.header.trailingButton.menu == nil)
        controller.header.trailingButton.sendActions(for: .touchUpInside)
        #expect(controller.editingMessageID == nil)
        #expect(controller.header.trailingButton.menu?.identifier == menu.identifier)
    }

    /// The theme's text size is the front conversation's: a sheet's conversation without one
    /// takes it, and the zoomed one under it gets it back (and re-measures) when the sheet goes.
    @Test(.timeLimit(.minutes(1))) func theFrontConversationOwnsTheThemeTextSize() async throws {
        let (zoomed, window) = try await loaded([Self.message("m1", "Zoomed", seq: 1)])
        defer {
            zoomed.textSize = nil
            ConversationThemeOwners.disappeared(zoomed)
            zoomed.store.stop(); window.isHidden = true
        }
        zoomed.textSize = .accessibilityLarge
        #expect(ConversationTheme.textSizeTraits?.preferredContentSizeCategory == .accessibilityLarge)
        let sheet = ConversationViewController(store: ConversationStore(backend: HooksBackend(messages: [])), options: .chief)
        defer { sheet.store.stop() }
        sheet.loadViewIfNeeded()
        ConversationThemeOwners.appeared(sheet)
        #expect(ConversationTheme.textSizeTraits == nil)
        ConversationThemeOwners.disappeared(sheet)
        #expect(ConversationTheme.textSizeTraits?.preferredContentSizeCategory == .accessibilityLarge)
        #expect(ConversationTheme.bubbleFont.pointSize == 33)
    }

    /// The zoom counts from the person's own size once the screen is in a window.
    @Test(.timeLimit(.minutes(1))) func zoomStepsFromThePersonsSizeInTheWindow() throws {
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil))
        let conversation = ConversationViewController(store: session.store, options: .chief)
        let container = ChiefConversationContainer(conversation: conversation, session: session)
        let host = UIViewController()
        host.traitOverrides.preferredContentSizeCategory = .extraExtraLarge
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        defer { session.store.stop(); ChiefTextZoom.shared.actualSize(); window.isHidden = true }
        ChiefTextZoom.shared.actualSize()
        ChiefTextZoom.shared.zoomIn(system: .extraExtraLarge)
        host.addChild(container)
        host.view.addSubview(container.view)
        container.didMove(toParent: host)
        container.beginAppearanceTransition(true, animated: false)
        container.endAppearanceTransition()
        host.view.layoutIfNeeded()
        #expect(container.systemTextSize == .extraExtraLarge)
        #expect(conversation.textSize == .extraExtraExtraLarge)
        ConversationThemeOwners.disappeared(conversation)
    }

    /// Chat Colors: this conversation's bubbles in the host's colours; nil draws Messages' own.
    @Test(.timeLimit(.minutes(1))) func bubbleColorsDrawThisConversationsBubblesAndNilKeepsMessages() async throws {
        let mine = ConversationMessage(id: "m1", seq: 1, clientMessageID: nil, senderID: "me", sentAt: Date(), text: "Mine")
        let theirs = Self.message("m2", "Theirs", seq: 2)
        let (controller, window) = try await loaded([mine, theirs])
        defer { controller.bubbleColors = nil; ConversationThemeOwners.disappeared(controller); controller.store.stop(); window.isHidden = true }
        func cell(_ message: ConversationMessage) throws -> MessageCell {
            controller.view.layoutIfNeeded()
            controller.collectionView.layoutIfNeeded()
            let path = try #require(controller.indexPath(for: message.rowID))
            return try #require(controller.collectionView.cellForItem(at: path) as? MessageCell)
        }
        let traits = controller.traitCollection
        #expect(try cell(mine).bubble.screenGradient != nil)
        #expect(try cell(mine).bubble.fillColor == ConversationTheme.outgoingBubble)
        #expect(try cell(theirs).bubble.fillColor == ConversationTheme.incomingBubble)
        let green = try #require(ConversationColor(hex: "#34C759"))
        let navy = try #require(ConversationColor(hex: "#1C2A4A"))
        controller.bubbleColors = ConversationBubbleColors(sent: green, received: navy)
        let sent = try cell(mine)
        #expect(sent.bubble.screenGradient == nil)
        #expect(sent.bubble.fillColor.resolvedColor(with: traits) == UIColor(conversation: green))
        #expect(sent.textLabel.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == UIColor(conversation: .black))
        let received = try cell(theirs)
        #expect(received.bubble.fillColor.resolvedColor(with: traits) == UIColor(conversation: navy))
        #expect(received.textLabel.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == UIColor(conversation: .white))
        controller.bubbleColors = nil
        #expect(ConversationTheme.bubbleColors == nil)
        #expect(try cell(mine).bubble.screenGradient != nil)
        #expect(try cell(theirs).bubble.fillColor == ConversationTheme.incomingBubble)
    }

    @Test(.timeLimit(.minutes(1))) func chiefScreenPutsInviteAndTheZoomInItsPageMenu() throws {
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil))
        let conversation = ConversationViewController(store: session.store, options: .chief)
        let container = ChiefConversationContainer(conversation: conversation, session: session)
        container.loadViewIfNeeded()
        defer { session.store.stop(); ChiefTextZoom.shared.actualSize() }
        let menu = try #require(conversation.headerActionMenu)
        #expect((menu.children.first as? UIAction)?.title == "Invite to cmux")
        #expect(menu.children.count == 2 && menu.children.last is UIDeferredMenuElement)
        // Chat Colors… waits until the chat is known (this one never connects).
        #expect(container.chatColorsAction().title == "Chat Colors…")
        #expect(container.chatColorsAction().attributes.contains(.disabled))
        #expect(conversation.options.trailingSymbol == ChiefPageMenu.symbol)
        ChiefTextZoom.shared.actualSize()
        let zoomMenu = container.zoomMenu()
        #expect(zoomMenu.children.compactMap { ($0 as? UIAction)?.title } == ["Zoom In", "Zoom Out", "Actual Size"])
        #expect((zoomMenu.children.last as? UIAction)?.attributes.contains(.disabled) == true)
        ChiefTextZoom.shared.zoomIn(system: container.systemTextSize)
        container.applyTextZoom()
        #expect(conversation.textSize == container.systemTextSize.stepped(by: 1))
        ChiefTextZoom.shared.actualSize()
        container.applyTextZoom()
        #expect(conversation.textSize == nil)
    }
}

private final class HooksBackend: ConversationBackend, Sendable {
    let messages: [ConversationMessage]
    init(messages: [ConversationMessage]) { self.messages = messages }
    func events() -> AsyncStream<ConversationBackendEvent> { AsyncStream { $0.finish() } }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        .init(messages: messages, hasMore: false)
    }
    private var unsupported: ConversationBackendError { .init(code: -1, message: "No writes in hook tests") }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage { throw unsupported }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { throw unsupported }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { throw unsupported }
    func unsend(messageID: String) async throws -> ConversationMessage { throw unsupported }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { throw unsupported }
    func close() {}
}
#endif

/// Chat Colors kept on the phone, per chat.
@MainActor
@Suite final class ChiefChatColorsTests {
    private let name = "chief-colors-\(UUID().uuidString)"
    deinit { UserDefaults().removePersistentDomain(forName: name) }

    @Test func eachChatKeepsItsOwnColoursAndResetForgetsThem() throws {
        let defaults = try #require(UserDefaults(suiteName: name))
        let store = ChiefChatColors(defaults: defaults)
        let a = ChiefChatColors.key(macID: "mac-1", conversation: "c1")
        let b = ChiefChatColors.key(macID: nil, conversation: "c1")
        #expect(a == "mac-1|c1" && b == "cloud|c1")
        let green = try #require(ConversationColor(hex: "#34C759"))
        store.update(a) { $0.sent = green }
        #expect(store.colors(for: a).sent == green)
        #expect(store.colors(for: b).isEmpty)
        #expect(ChiefChatColors(defaults: defaults).colors(for: a).sent == green)
        store.update(a) { $0.sent = nil }
        #expect(store.chats[a] == nil)
        #expect(ChiefChatColors(defaults: defaults).chats.isEmpty)
    }

    /// One saved chat this build cannot read never drops the others.
    @Test func oneUnreadableChatKeepsTheRest() throws {
        let saved = Data(##"{"mac|a":{"sent":"#34C759"},"mac|b":{"sent":"not a colour"}}"##.utf8)
        let chats = ChiefChatColors.decode(saved)
        #expect(chats.keys.sorted() == ["mac|a"])
        #expect(chats["mac|a"]?.sent?.hex == "#34C759")
    }
}
