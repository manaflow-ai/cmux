#if DEBUG
public import AppKit
import CmuxHomeCore

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
    // task-owner: kept and cancelled in `close()`
    private var loading: Task<Void, Never>?

    /// With `attachments`, the conversation also gets a photo, a video and a
    /// PDF from me (prepared and sent through the store like a drop).
    private let attachments: Bool

    public init(attachments: Bool = false) {
        self.attachments = attachments
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
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: me)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        self.view = view
        await view.binding.opened()
        if attachments { await addAttachments(in: id) }
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
