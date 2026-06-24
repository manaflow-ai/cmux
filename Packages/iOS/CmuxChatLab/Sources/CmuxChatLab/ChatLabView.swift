#if canImport(UIKit)
import CmuxAgentChat
import SwiftUI

/// DEBUG-only entry point for the chat lab. Boots a fixture-driven
/// `ChatConversationStore` and hosts the UIKit chat subsystem. Reached from the
/// root scene when `CMUX_CHAT_LAB=1`; the fixture is chosen by
/// `CMUX_CHAT_FIXTURE` (defaults to `wrapping`).
public struct ChatLabView: View {
    @State private var model: Model

    public init(fixture rawFixture: String?) {
        _model = State(initialValue: Model(fixture: ChatLabFixture.resolve(rawFixture)))
    }

    public var body: some View {
        ChatLabRepresentable(store: model.store)
            .ignoresSafeArea()
            .task { await model.run() }
    }

    @MainActor
    final class Model {
        let store: ChatConversationStore
        private let source: FixtureChatEventSource

        init(fixture: ChatLabFixture) {
            let scenario = fixture.scenario(now: Date())
            let source = FixtureChatEventSource(
                backlog: scenario.backlog,
                replyToSends: scenario.replyToSends
            )
            self.source = source
            self.store = ChatConversationStore(
                descriptor: scenario.descriptor,
                source: source,
                pageSize: scenario.pageSize,
                maxWindowCount: scenario.maxWindowCount
            )
        }

        func run() async { await store.run() }
    }
}

private struct ChatLabRepresentable: UIViewControllerRepresentable {
    let store: ChatConversationStore

    func makeUIViewController(context: Context) -> ChatLabViewController {
        ChatLabViewController(store: store)
    }

    func updateUIViewController(_ controller: ChatLabViewController, context: Context) {}
}
#endif
