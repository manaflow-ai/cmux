#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxHomeCore
public import CmuxNextDesign

/// DEBUG ONLY. A fixture for screenshots and dogfood: the real
/// `HomeNativeTranscriptView` (MessagesLab's code) over a
/// `HomeStore` over CmuxHomeCore's mock owner, showing its first (chief)
/// conversation. Compiled out of Release.
@MainActor
public final class HomeNativeFixture {
    public let container = NSView()
    /// The fixture tab's title.
    public static var title: String { HomeStrings.conversations }
    /// No latency; the Chief types for 1.5 s before it answers (the typing
    /// indicator shows, as in MessagesLab's script).
    private let source = MockHomeSource(options: .init(chiefHistory: 300, latency: .zero, replyDelay: .milliseconds(1500)))
    private let store: HomeStore
    private var view: HomeNativeTranscriptView?
    /// The shown conversation and its Chief (set once the view shows).
    private var shown: (conversation: ConversationID, chief: ParticipantID)?
    /// The Chief's streamed turn (`debugStream`) and its last draft seq.
    private var streamTurn: IdempotencyKey?
    private var streamSeq: UInt64 = 0
    // task-owner: kept and cancelled in `close()`
    private var loading: Task<Void, Never>?

    /// With `attachments`, the conversation also gets a photo, a video and a
    /// PDF from me (prepared and sent through the store like a drop).
    private let attachments: Bool
    /// With `cards`, the Chief also posts its three cards (cmux issue 25830): a live browser card with a
    /// screenshot, a reply with next-step chips (one already chosen) and a Secure Store sign-in card.
    private let cards: Bool
    /// The app's made-ahead file picker for the fixture's "+"; nil opens none.
    private let openPanel: MadeAheadOpenPanel?

    public init(attachments: Bool = false, cards: Bool = false, openPanel: MadeAheadOpenPanel? = nil) {
        self.attachments = attachments
        self.cards = cards
        self.openPanel = openPanel
        store = HomeStore(source: source)
        store.start()
        loading = Task { [weak self] in await self?.load() }
    }

    /// Stops the store and the binding (the fixture tab closed).
    public func close() {
        loading?.cancel()
        view?.stop()
        store.stop()
    }

    private func load() async {
        let chief = await source.chief.id
        guard let inbox = try? await source.inbox(), !Task.isCancelled,
              let id = (inbox.conversations.first { $0.participants.contains { $0.id == chief } && $0.participants.count == 2 }
                  ?? inbox.conversations.first)?.id else { return }
        let me = inbox.me.id
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: me, openPanel: openPanel)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        self.view = view
        shown = (id, chief)
        await view.binding.opened()
        if attachments { await addAttachments(in: id) }
        if cards { await addCards(in: id, chief: chief, me: me) }
    }

    /// True when `view` is this fixture's transcript.
    public func shows(_ view: HomeNativeTranscriptView) -> Bool { self.view === view }

    /// Streams `text` as the Chief's running reply, the whole reply so far (an owner's fresh draft item);
    /// `done` ends the turn and posts `text` as the Chief's message. False before the conversation shows.
    public func debugStream(_ text: String, done: Bool) -> Bool {
        guard let shown else { return false }
        let turn = streamTurn ?? .make()
        streamTurn = done ? nil : turn
        streamSeq += 1
        let update = HomeDraftUpdate(conversation: shown.conversation, participant: shown.chief, turn: turn, segment: 0,
                                     seq: streamSeq, isTalk: true, text: text, fresh: true, done: done)
        let source = self.source
        // task-owner: one owner event, ends when the mock source has published it
        Task {
            await source.streamDraft(update)
            if done { await source.receive(text, from: shown.chief, in: shown.conversation) }
        }
        return true
    }

    /// The Chief's cards as the reference screenshots show them (Chief chat, 2026-10-26).
    private func addCards(in id: ConversationID, chief: ParticipantID, me: ParticipantID) async {
        // The browser card's screenshot: an attachment record of the conversation, as the Chief uploads it.
        var image: ChiefCard.Image?
        if let photo = try? await HomeFixtureMedia.make().first,
           let prepared = try? await store.prepareAttachment(fileURL: photo, keepLocation: false),
           let ref = try? await source.upload(AttachmentUpload(conversation: id, fileURL: prepared.fileURL, ref: prepared.ref,
                                                               previewURL: prepared.previewURL)) {
            image = ChiefCard.Image(hash: ref.hash, mimeType: ref.mimeType, byteCount: ref.byteCount, width: ref.width, height: ref.height)
        }
        guard !Task.isCancelled else { return }
        let posts: [(ParticipantID, [MessagePart])] = [
            (me, [.text("then reply to junbeom or something")]),
            (chief, [.card(.browser(step: "Returning to LinkedIn Messaging", live: true, target: "browser:right",
                                    url: "https://www.linkedin.com/messaging/", image: image))]),
            (chief, [.text("Also done since you asked: the apology replies to Jeff and daval.ai are sent and verified. "
                           + "The Jun Beom Lee LinkedIn reply for Wed Oct 28 at 10 AM is in progress."),
                     .card(.nextSteps(["Try sending the Kernel update again", "Check the Nov 4 event thread"]))]),
            (chief, [.card(.signIn(site: "linkedin.com", url: "https://www.linkedin.com/login"))]),
            (me, [.text("Check the Nov 4 event thread")]),
        ]
        for (author, parts) in posts { await source.post(parts, from: author, in: id, key: .make()) }
    }

    /// Holds the fixture's activity state for matching light/dark captures.
    /// No agent runs and no timer is installed; closing the fixture stops its store.
    public func debugTyping(_ on: Bool) -> Bool {
        guard let shown else { return false }
        let source = self.source
        // task-owner: one mock event, finishes after it is published
        Task { await source.typing(shown.chief, in: shown.conversation, on: on) }
        return true
    }

    private func addAttachments(in id: ConversationID) async {
        guard let files = try? await HomeFixtureMedia.make(), !Task.isCancelled else { return }
        for file in files {
            guard let prepared = try? await store.prepareAttachment(fileURL: file, keepLocation: false) else { continue }
            try? await store.send(conversation: id, text: "", attachments: [prepared])
        }
    }
}
#endif
