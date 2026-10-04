#if DEBUG
public import AppKit
import CmuxHomeCore
import CmuxHomeRender

/// DEBUG ONLY. A fixture for screenshots and dogfood: the real
/// `HomeNativeTranscriptView` wired with the real `HomeStoreBinding` to a
/// `HomeStore` over CmuxHomeCore's mock owner, showing its first (chief)
/// conversation. Compiled out of Release.
@MainActor
public final class HomeNativeFixture {
    public let container = NSView()
    /// The fixture tab's title.
    public static var title: String { HomeStrings.conversations }
    private let source = MockHomeSource(options: .immediate)
    private let store: HomeStore
    private var binding: HomeStoreBinding?
    private var view: HomeNativeTranscriptView?
    // task-owner: kept and cancelled in `close()`
    private var loading: Task<Void, Never>?

    /// With `attachments`, the conversation also gets a photo, a video and a
    /// PDF from me, served by a local fake loader, and the composer takes
    /// drops, pastes and picked files through a local fake preparer.
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
        binding?.stop()
        store.stop()
    }

    private func load() async {
        guard let inbox = try? await source.inbox(), let id = inbox.conversations.first?.id, !Task.isCancelled else { return }
        let me = inbox.me.id
        await store.open(id)
        let view = HomeNativeTranscriptView(conversation: id, me: me)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        self.view = view
        binding = HomeStoreBinding(store: store, controller: view.controller)
        if attachments { await addAttachments(to: view, in: id) }
    }

    private func addAttachments(to view: HomeNativeTranscriptView, in id: ConversationID) async {
        view.attachmentPreparer = store
        binding?.onAttachmentRefusal = { [weak view] _, refusal in view?.showAttachmentRefusal(refusal) }
        guard let files = try? await HomeFixtureMedia.make(), !Task.isCancelled else { return }
        for file in files {
            guard let prepared = try? await store.prepareAttachment(fileURL: file) else { continue }
            try? await store.send(conversation: id, text: "", attachments: [prepared])
        }
    }
}
#endif
