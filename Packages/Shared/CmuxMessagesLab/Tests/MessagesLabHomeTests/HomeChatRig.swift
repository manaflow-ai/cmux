import AppKit
@testable import CmuxHomeCore
import Foundation
@testable import MessagesLabHome

/// The real Home view (`MessagesLabHomeView`) over a real `HomeStore` on the mock owner, in an
/// offscreen window, with the Chief's live runs driven by hand (plans/cmux-next/home-chat-pipeline-DESIGN.md
/// section 4). Every bubble a test makes carries `tag`, so the checks skip the generated history.
@MainActor
final class HomeChatRig {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")
    static let tag = "⟨"

    let source: MockHomeSource
    let store: HomeStore
    let window: NSWindow
    let view: MessagesLabHomeView
    let me: ParticipantID
    let chief: ParticipantID

    init(history: Int = 40, width: CGFloat = 700) async throws {
        // The mock owner's own answer to a send comes after the test ends.
        source = MockHomeSource(options: MockHomeSource.Options(chiefHistory: history, latency: .zero, replyDelay: .seconds(3600)))
        store = HomeStore(source: source)
        store.start()
        await Self.until { [store] in store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await Self.until { [store] in !store.transcript(for: Self.conversation).isEmpty }
        guard let me = store.me?.id else { throw RigError.noMe }
        self.me = me
        chief = await source.chief.id
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // The order, property and stress tests check the stream bubbles (HomeReplyDisplay.streaming).
        view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake(), replies: .streaming)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.controller.nextFrame = { [frames] f in frames.held.append(f) }
    }

    enum RigError: Error { case noMe }

    func stop() {
        view.stop()
        window.close()
        store.stop()
    }

    static func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    /// Work the view holds for the next display frame (`ChatController.nextFrame`; an offscreen
    /// window has no display link): it runs at the start of each `frame()`.
    private final class Frames {
        var held: [() -> Void] = []
        func start() { let w = held; held = []; w.forEach { $0() } }
    }
    private let frames = Frames()

    /// One display frame and one store pass, as the app runs them: the frame's held work first
    /// (a stream update held for this frame, HomeStreamPacer), then the store pass.
    func frame() {
        frames.start()
        view.projection.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        CATransaction.flush()
    }

    func resize(width: CGFloat) {
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        window.setContentSize(NSSize(width: width, height: 900))
        frame()
    }

    // MARK: Traffic

    /// Return in the field with `text`, then the store logs it (`HomeProjection.send` hands it
    /// to HomeStore in a task: until then only the view's local bubble shows it).
    @discardableResult
    func send(_ text: String) async -> String? {
        view.controller.dispatch(.setDraft(text))
        let refusal = view.projection.send()
        if refusal == nil { await Self.until { [store] in store.transcript(for: Self.conversation).contains { $0.plainText == text } } }
        frame()
        return refusal
    }

    /// A `chief-live-v1` talk delta of `run`.
    func delta(_ run: String, seq: UInt64, _ text: String, author: ParticipantID? = nil, step: String = "talk") {
        store.handle(.live(.delta(HomeLiveDelta(conversation: Self.conversation, author: author ?? chief, run: run, step: step,
                                                isTalk: true, seq: seq, text: text, isFinal: false))))
    }

    /// A run record change (`running`, `done`, `failed`, `cancelled`).
    func run(_ run: String, _ status: String, author: ParticipantID? = nil) {
        store.handle(.live(.run(HomeLiveRunChange(conversation: Self.conversation, author: author ?? chief, run: run,
                                                  turn: nil, status: status))))
    }

    /// The Chief posts `text` under `key` (a run's reply: its run id) and the store has its echo.
    @discardableResult
    func post(_ text: String, key: IdempotencyKey) async -> Bool {
        guard await source.post(text, from: chief, in: Self.conversation, key: key) != nil else { return false }
        await Self.until { [store] in store.transcript(for: Self.conversation).contains { $0.key == key && $0.seq != nil } }
        return store.transcript(for: Self.conversation).contains { $0.key == key && $0.seq != nil }
    }

    /// The Chief posts `parts` under `key` in `threadRoot`'s thread and the store has its echo.
    @discardableResult
    func post(_ parts: [MessagePart], key: IdempotencyKey, threadRoot: MessageID? = nil) async -> Bool {
        guard await source.post(parts, from: chief, in: Self.conversation, key: key, threadRoot: threadRoot) != nil else { return false }
        await Self.until { [store] in store.transcript(for: Self.conversation).contains { $0.key == key && $0.seq != nil } }
        return store.transcript(for: Self.conversation).contains { $0.key == key && $0.seq != nil }
    }

    func holdSends() async { await source.holdSubmits() }

    /// Lets the held sends go and waits for every tagged send to commit.
    func releaseSends() async {
        await source.releaseSubmits()
        await Self.until { [store] in
            !store.transcript(for: Self.conversation).contains { $0.plainText.hasPrefix(Self.tag) && $0.seq == nil }
        }
    }

    // MARK: Reading

    /// The bubbles the transcript shows, oldest first (streams last, as RowBuilder draws them), tagged ones only.
    func bubbles() -> [String] {
        guard let s = view.controller.store?.state else { return [] }
        let streams = s.ui.streams.filter { !$0.parts.isEmpty }.map(\.message)
        return (s.conversation.messages + streams).map { m in
            m.parts.compactMap { if case let .text(t, _) = $0 { t } else { nil } }.joined()
        }.filter { $0.hasPrefix(Self.tag) }
    }

    /// The store's tagged transcript rows in its order (committed by seq, then my pending sends).
    func storeItems() -> [String] {
        store.transcript(for: Self.conversation).map(\.plainText).filter { $0.hasPrefix(Self.tag) }
    }
}

extension HomeStore {
    /// Shows `draft` as an owner's fresh `conversation-draft` item sends it (its whole text at its
    /// `lastSeq`), through the store's event path; nil ends the turn's draft (its `done` item).
    func showDraft(_ draft: HomeTurnDraft?, turn: IdempotencyKey, author: ParticipantID, in conversation: ConversationID) {
        let update = HomeDraftUpdate(conversation: conversation, participant: author, turn: turn, segment: 0,
                                     seq: draft?.lastSeq ?? UInt64.max, isTalk: true, text: draft?.text ?? "",
                                     fresh: true, done: draft == nil)
        handle(.draft(update))
    }
}
