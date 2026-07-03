#if canImport(UIKit) && DEBUG
import CmuxAgentChat
import CmuxAgentChatUI
import SwiftUI

/// DEBUG-only self-playing agent chat used to record and verify the live
/// streaming-prose preview on the simulator, with no sign-in or Mac pairing.
///
/// Mounted by the root view when ``UITestConfig/streamingChatPreviewEnabled`` is
/// set (`CMUX_UITEST_STREAMING_CHAT_PREVIEW=1`). It builds the production
/// ``ChatConversationStore`` + ``ChatScreen`` and drives them with real
/// ``ChatSessionEvent/streamingProse`` events that grow word by word, then clear
/// — exactly the wire traffic the Mac host emits while a turn streams — so the
/// recording exercises the real store/projector/transcript render path.
struct StreamingChatPreviewView: View {
    @State private var model: Model?

    var body: some View {
        Group {
            if let model {
                ChatScreen(store: model.store, onOpenTerminal: {})
            } else {
                ProgressView()
                    .task { await start() }
            }
        }
    }

    @MainActor
    private func start() async {
        guard model == nil else { return }
        let (messages, descriptor) = StreamingPreviewSeedConversation(
            environment: ProcessInfo.processInfo.environment
        ).make()
        let source = FixtureChatEventSource(backlog: messages)
        let store = ChatConversationStore(descriptor: descriptor, source: source)
        let model = Model(store: store, source: source)
        model.runTask = Task { await store.run() }
        model.driveTask = Task { await Self.drive(source: source) }
        self.model = model
    }

    /// Loops the streaming lifecycle so any recording window captures a full
    /// build: grow the answer word by word via `streamingProse`, hold, then
    /// clear with `streamingProse(nil)`, and repeat.
    private static func drive(source: FixtureChatEventSource) async {
        let full = "The sky looks blue because air scatters short blue wavelengths most. "
            + "Blue is widely tied to calm, depth, and quiet focus. "
            + "From sapphires to the open ocean, it runs through the natural world."
        let words = full.split(separator: " ").map(String.init)
        // Let ChatScreen subscribe and load the seeded prompt first.
        try? await Task.sleep(for: .milliseconds(1200))
        while !Task.isCancelled {
            var accumulated = ""
            for word in words {
                if Task.isCancelled { return }
                accumulated += accumulated.isEmpty ? word : " " + word
                await source.emit(.streamingProse(previewMessage(text: accumulated)))
                try? await Task.sleep(for: .milliseconds(130))
            }
            try? await Task.sleep(for: .milliseconds(1500))
            await source.emit(.streamingProse(nil))
            try? await Task.sleep(for: .milliseconds(800))
        }
    }

    private static func previewMessage(text: String) -> ChatMessage {
        ChatMessage(
            id: "stream:streaming-preview",
            seq: Int.max - 1,
            role: .agent,
            timestamp: Date(),
            kind: .prose(ChatProse(text: text))
        )
    }

    /// Retains the store, source, and driver tasks across re-renders; cancels
    /// the tasks on teardown.
    @MainActor
    final class Model {
        let store: ChatConversationStore
        let source: FixtureChatEventSource
        var runTask: Task<Void, Never>?
        var driveTask: Task<Void, Never>?

        init(store: ChatConversationStore, source: FixtureChatEventSource) {
            self.store = store
            self.source = source
        }

        deinit {
            runTask?.cancel()
            driveTask?.cancel()
        }
    }
}

#endif
