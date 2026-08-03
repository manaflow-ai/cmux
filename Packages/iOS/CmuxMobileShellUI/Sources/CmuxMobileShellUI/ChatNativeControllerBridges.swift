#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileToast
import SwiftUI
import UIKit

private struct ChatArtifactLoaderEnvironmentKey: EnvironmentKey {
    static let defaultValue = ChatArtifactLoader.unsupported()
}

extension EnvironmentValues {
    var chatArtifactLoader: ChatArtifactLoader {
        get { self[ChatArtifactLoaderEnvironmentKey.self] }
        set { self[ChatArtifactLoaderEnvironmentKey.self] = newValue }
    }
}

/// Temporary composition bridge while the surrounding mobile shell moves to UIKit.
struct ChatScreen: UIViewControllerRepresentable {
    let store: ChatConversationStore
    @Binding var draft: String
    let accessoryLeadingShortcuts: [ChatAccessoryShortcut]
    let accessoryShortcuts: [ChatAccessoryShortcut]
    let providesOwnChrome: Bool
    let runsStoreTask: Bool
    let onOpenTerminal: @MainActor () -> Void

    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.chatArtifactLoader) private var artifactLoader

    init(
        store: ChatConversationStore,
        draft: Binding<String> = .constant(""),
        accessoryLeadingShortcuts: [ChatAccessoryShortcut] = [],
        accessoryShortcuts: [ChatAccessoryShortcut] = [],
        providesOwnChrome: Bool = true,
        runsStoreTask: Bool = true,
        onOpenTerminal: @escaping @MainActor () -> Void
    ) {
        self.store = store
        _draft = draft
        self.accessoryLeadingShortcuts = accessoryLeadingShortcuts
        self.accessoryShortcuts = accessoryShortcuts
        self.providesOwnChrome = providesOwnChrome
        self.runsStoreTask = runsStoreTask
        self.onOpenTerminal = onOpenTerminal
    }

    func makeUIViewController(context: Context) -> ChatViewController {
        ChatViewController(
            store: store,
            draft: nativeDraftBinding,
            accessoryLeadingShortcuts: accessoryLeadingShortcuts,
            accessoryShortcuts: accessoryShortcuts,
            artifactLoader: artifactLoader,
            toastCenter: toastCenter,
            providesOwnChrome: providesOwnChrome,
            runsStoreTask: runsStoreTask,
            onOpenTerminal: onOpenTerminal
        )
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {
        controller.update(
            draft: nativeDraftBinding,
            accessoryLeadingShortcuts: accessoryLeadingShortcuts,
            accessoryShortcuts: accessoryShortcuts,
            artifactLoader: artifactLoader,
            theme: ChatTheme()
        )
    }

    private var nativeDraftBinding: ChatDraftBinding {
        let draft = $draft
        return ChatDraftBinding(
            get: { draft.wrappedValue },
            set: { draft.wrappedValue = $0 }
        )
    }
}

/// Temporary navigation bridge for native artifact controllers.
struct ChatArtifactViewerDestination: UIViewControllerRepresentable {
    let path: String
    let scope: ChatArtifactViewerScope
    let swipeOrder: ChatArtifactGallerySwipeOrder
    let onDone: @MainActor () -> Void

    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.chatArtifactLoader) private var loader

    init(
        path: String,
        scope: ChatArtifactViewerScope = .chat,
        swipeOrder: ChatArtifactGallerySwipeOrder = ChatArtifactGallerySwipeOrder(items: []),
        onDone: @escaping @MainActor () -> Void
    ) {
        self.path = path
        self.scope = scope
        self.swipeOrder = swipeOrder
        self.onDone = onDone
    }

    func makeUIViewController(context: Context) -> ChatArtifactViewerController {
        ChatArtifactViewerController(
            path: path,
            scope: scope,
            swipeOrder: swipeOrder,
            loader: loader,
            toastCenter: toastCenter,
            onDone: onDone
        )
    }

    func updateUIViewController(
        _ controller: ChatArtifactViewerController,
        context: Context
    ) {
        controller.update(path: path, swipeOrder: swipeOrder)
    }
}

extension View {
    /// Presents system Share or Save controllers for a prepared artifact file.
    func chatArtifactFileActionPresentation(
        _ presentation: Binding<ChatArtifactFileActionPresentation?>
    ) -> some View {
        modifier(ChatArtifactFileActionPresentationModifier(presentation: presentation))
    }
}

private struct ChatArtifactFileActionPresentationModifier: ViewModifier {
    @Binding var presentation: ChatArtifactFileActionPresentation?

    func body(content: Content) -> some View {
        content.sheet(item: $presentation) { item in
            switch item {
            case .share(let fileURL):
                ChatArtifactActivityController(fileURL: fileURL) {
                    finish(item)
                }
            case .save(let fileURL):
                ChatArtifactDocumentPickerController(fileURL: fileURL) {
                    finish(item)
                }
            }
        }
    }

    private func finish(_ item: ChatArtifactFileActionPresentation) {
        presentation = nil
        Task {
            await ChatArtifactFileActionStore.applicationDefault.remove(item.fileURL)
        }
    }
}

private struct ChatArtifactActivityController: UIViewControllerRepresentable {
    let fileURL: URL
    let onFinish: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        controller.loadViewIfNeeded()
        controller.popoverPresentationController?.sourceView = controller.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: controller.view.bounds.midX,
            y: controller.view.bounds.midY,
            width: 1,
            height: 1
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onFinish() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ChatArtifactDocumentPickerController: UIViewControllerRepresentable {
    let fileURL: URL
    let onFinish: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forExporting: [fileURL],
            asCopy: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ controller: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: @MainActor () -> Void

        init(onFinish: @escaping @MainActor () -> Void) {
            self.onFinish = onFinish
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onFinish()
        }
    }
}
#endif
