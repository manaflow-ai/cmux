import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.serialized, .closesItsWindows) struct HomeStarterTests {
    @Test func suggestionsReflectAvailableWorkAndStayBounded() {
        let context = HomeStarterContext(workspaces: ["todo-app", "docs", "docs", "site"], working: ["Add search"],
                                         failures: ["Run tests"], pullRequests: ["sample/todo#42"])
        #expect(context.prompts == [HomeStarterStrings.failure("Run tests"), HomeStarterStrings.running("Add search"),
                                    HomeStarterStrings.review("sample/todo#42"), HomeStarterStrings.workspace("todo-app"),
                                    HomeStarterStrings.workspace("docs")])
        #expect(HomeStarterContext().prompts == [HomeStarterStrings.setup, HomeStarterStrings.agent, HomeStarterStrings.task])
        #expect(HomeStarterContext(workspaces: ["todo-app"]).prompts.count == 3)
    }

    @Test func unchangedActivityKeepsButtonsAndChangedActivityReplacesIt() throws {
        let chips = HomeStarterChips(frame: NSRect(x: 0, y: 0, width: 340, height: 200))
        chips.setPrompts(HomeStarterContext(working: ["Add search"]).prompts)
        let original = try #require(chips.buttons.first)
        chips.setPrompts(HomeStarterContext(working: ["Add search"]).prompts)
        #expect(chips.buttons.first === original)
        var sent: [String] = []
        chips.onSend = { sent.append($0) }
        original.performClick(nil)
        #expect(sent == [HomeStarterStrings.running("Add search")])
        chips.isEnabled = false
        original.performClick(nil)
        #expect(sent.count == 1)
        chips.setPrompts(HomeStarterContext(failures: ["Test search"]).prompts)
        #expect(chips.buttons.first?.title == HomeStarterStrings.failure("Test search"))
    }

    @Test func narrowPanesAndLongTranslationsStayAboveComposer() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 280, height: 800))
        panel.starters.setPrompts(HomeStarterContext(workspaces: [String(repeating: "long workspace ", count: 20)],
                                                    working: ["Add search"], failures: ["Run tests"]).prompts)
        for height in stride(from: 800, through: 100, by: -50) {
            panel.setFrameSize(NSSize(width: 280, height: height))
            panel.layoutSubtreeIfNeeded()
            for view in [panel.hero, panel.starters, panel.switchCard] + panel.actionRows where !view.isHiddenOrHasHiddenAncestor {
                #expect(panel.convert(view.bounds, from: view).maxY <= panel.bounds.height + 1)
            }
            for button in panel.starters.buttons {
                #expect(button.frame.maxX <= panel.starters.bounds.width + 1)
            }
        }
    }

    @Test func savedAttachmentRestorationCannotSendAStarter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-starter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = EmptyChiefSource(), id = ConversationID("conv_chief")
        let store = HomeStore(source: source, blobCacheDirectory: root)
        let inbox = try await source.inbox()
        store.start()
        await store.open(id)
        let attachment = try await store.prepareAttachment(data: Data("saved draft".utf8), typeIdentifier: "public.plain-text")
        store.setDraftAttachments([attachment], for: id)
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        defer { view.stop(); store.close(id); store.stop() }
        view.setFirstRunStarters(HomeStarterContext())
        #expect(!view.firstRun.isHidden)
        #expect(view.transcript.isRestoringDraftAttachments)
        #expect(view.transcript.draftAttachments.isEmpty)
        #expect(!view.firstRun.starters.isEnabled)
        view.sendStarter(HomeStarterStrings.setup)
        #expect(!view.starterSent)
        #expect(view.transcript.draftText.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while view.transcript.isRestoringDraftAttachments, ContinuousClock.now < deadline { await Task.yield() }
        #expect(view.transcript.draftAttachments == [attachment])
        #expect(!view.transcript.draftText.contains(HomeStarterStrings.setup))
    }

    @Test func chipSendsExactlyOnceAndPreservesATypedDraft() async throws {
        let source = EmptyChiefSource()
        let id = ConversationID("conv_chief")
        let inbox = try await source.inbox()
        let originalIDs = Set(try await source.base.snapshot(of: id, tail: 10).messages.map(\.id))
        let store = HomeStore(source: source)
        store.start()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { view.stop(); store.stop(); window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        window.contentView = view
        await view.binding.opened()
        view.setFirstRunStarters(HomeStarterContext())
        view.layoutSubtreeIfNeeded()
        let button = try #require(view.firstRun.starters.buttons.first)
        view.showDraft("Keep this draft")
        button.performClick(nil)
        #expect(view.transcript.draftText == "Keep this draft")
        view.showDraft("")
        let preparer = HeldStarterAttachment()
        view.attachmentPreparer = preparer
        view.attach([.data(Data("draft".utf8), typeIdentifier: "public.plain-text")])
        button.performClick(nil)
        #expect(view.transcript.draftText.isEmpty)
        for await _ in preparer.begun.stream { break }
        button.performClick(nil)
        #expect(!view.starterSent)
        preparer.release?.resume()
        await view.attachmentsReady()
        #expect(view.firstRun.starters.isEnabled)
        view.isSendEnabled = false
        button.performClick(nil)
        #expect(view.transcript.draftText.isEmpty)
        view.isSendEnabled = true
        button.performClick(nil)
        button.performClick(nil)
        let deadline = ContinuousClock.now + .seconds(5)
        var sent: [Message] = []
        repeat {
            sent = try await source.base.snapshot(of: id, tail: 10).messages.filter { $0.author == inbox.me.id && !originalIDs.contains($0.id) }
            if !sent.isEmpty { break }
            await Task.yield()
        } while ContinuousClock.now < deadline
        #expect(sent.count == 1)
        #expect(sent.first?.parts == [.text(HomeStarterStrings.setup)])
    }
}

@MainActor private final class HeldStarterAttachment: HomeAttachmentPreparing {
    let begun = AsyncStream<Void>.makeStream()
    var release: CheckedContinuation<Void, Never>?
    func prepareAttachment(fileURL: URL, keepLocation: Bool) async throws -> LocalAttachment {
        throw HomeAttachmentError.empty(name: "draft")
    }
    func prepareAttachment(data: Data, typeIdentifier: String, keepLocation: Bool) async throws -> LocalAttachment {
        await withCheckedContinuation { release = $0; begun.continuation.yield(()) }
        throw HomeAttachmentError.empty(name: "draft")
    }
}

/// An empty initial Chief over the normal in-memory owner; later sends use its real ledger.
struct EmptyChiefSource: HomeSource {
    let base = MockHomeSource(options: .init(chiefHistory: 1, latency: .zero, replyDelay: .zero))
    func events() async -> AsyncStream<HomeEvent> {
        let snapshot = try? await inbox()
        return AsyncStream { stream in
            stream.yield(.connection(.online))
            if let snapshot { stream.yield(.inbox(snapshot)) }
            stream.finish()
        }
    }
    func inbox() async throws -> InboxSnapshot {
        var inbox = try await base.inbox()
        for index in inbox.conversations.indices where inbox.conversations[index].id == ConversationID("conv_chief") {
            inbox.conversations[index].lastSeq = 0
            inbox.conversations[index].lastMessage = nil
        }
        return inbox
    }
    func snapshot(of id: ConversationID, tail: Int) async throws -> ConversationPage {
        var page = try await base.snapshot(of: id, tail: tail)
        if page.conversation.lastSeq == 1 {
            page.conversation.lastSeq = 0
            page.conversation.lastMessage = nil
            page.messages = []
        }
        return page
    }
    func history(of id: ConversationID, before seq: Seq, limit: Int) async throws -> [Message] { [] }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult { try await base.submit(intent) }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { try await base.resolve(contact) }
}
