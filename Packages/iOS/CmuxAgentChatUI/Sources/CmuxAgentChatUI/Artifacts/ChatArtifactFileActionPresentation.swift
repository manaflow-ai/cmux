import SwiftUI

#if os(iOS)
import UIKit

/// A system presentation prepared by an artifact file action.
public enum ChatArtifactFileActionPresentation: Identifiable, Equatable {
    /// Presents the standard activity controller for a local file.
    case share(URL)
    /// Presents the Files document picker in export-as-copy mode.
    case save(URL)

    /// Stable identity for SwiftUI sheet presentation.
    public var id: String {
        switch self {
        case .share(let url):
            return "share:\(url.path)"
        case .save(let url):
            return "save:\(url.path)"
        }
    }

    fileprivate var fileURL: URL {
        switch self {
        case .share(let url), .save(let url):
            return url
        }
    }
}

public extension View {
    /// Presents Share or Save to Files for a materialized artifact.
    ///
    /// Temporary files are removed when the system controller finishes.
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
            case .share(let url):
                ChatArtifactActivityView(fileURL: url) {
                    finish(item)
                }
            case .save(let url):
                ChatArtifactDocumentPicker(fileURL: url) {
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

private struct ChatArtifactActivityView: UIViewControllerRepresentable {
    let fileURL: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            onFinish()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ChatArtifactDocumentPicker: UIViewControllerRepresentable {
    let fileURL: URL
    let onFinish: () -> Void

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
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
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
