import CmuxAgentChat
import Foundation
import SwiftUI

#if os(iOS)
import QuickLook
import UIKit
#endif

/// Embeds an artifact preview without navigation chrome.
public struct ChatArtifactInlineViewer: View {
    private struct LoadIdentity: Hashable {
        let path: String
        let retryGeneration: Int
    }

    private let path: String
    private let showsActions: Bool
    @Environment(\.chatArtifactLoader) private var loader
    @State private var pageModel: ChatArtifactViewerPageModel

    /// Creates an inline preview for one artifact path.
    /// - Parameters:
    ///   - path: Artifact path passed to the environment's ``ChatArtifactLoader``.
    ///   - showsActions: Whether loaded preview content exposes compact file actions.
    public init(path: String, showsActions: Bool = false) {
        self.path = path
        self.showsActions = showsActions
        _pageModel = State(initialValue: ChatArtifactViewerPageModel(
            path: path,
            textPreferences: ChatArtifactTextPreferences(defaults: .standard)
        ))
    }

    public var body: some View {
        let snapshot = pageModel.snapshot
        ChatArtifactViewerRouteView(
            snapshot: snapshot,
            scope: .terminal,
            actions: pageModel.actions(
                loader: loader,
                quickLookCanPreview: { fileURL in
                    #if os(iOS)
                    QLPreviewController.canPreview(ChatArtifactQuickLookItem(
                        fileURL: fileURL,
                        title: snapshot.displayName
                    ))
                    #else
                    false
                    #endif
                }
            ).renderingOnly,
            onDone: {}
        )
        .overlay(alignment: .topTrailing) {
            inlineActionBar(snapshot: snapshot)
        }
        .clipped()
        #if os(iOS)
        .chatArtifactFileActionPresentation(fileActionPresentationBinding)
        .alert(
            String(
                localized: "chat.artifact.action_failed.title",
                defaultValue: "Couldn't complete action",
                bundle: .module
            ),
            isPresented: fileActionErrorBinding
        ) {
            Button(String(localized: "chat.artifact.ok", defaultValue: "OK", bundle: .module)) {}
        } message: {
            Text(String(
                localized: "chat.artifact.action_failed.message",
                defaultValue: "Check the connection to your Mac and try again.",
                bundle: .module
            ))
        }
        #endif
        .task(id: LoadIdentity(path: path, retryGeneration: snapshot.retryGeneration)) {
            let activeModel = model(for: path)
            await activeModel.load(
                loader: loader,
                quickLookCanPreview: { fileURL in
                    #if os(iOS)
                    QLPreviewController.canPreview(ChatArtifactQuickLookItem(
                        fileURL: fileURL,
                        title: URL(fileURLWithPath: path).lastPathComponent
                    ))
                    #else
                    false
                    #endif
                }
            )
            await waitForViewerTaskCancellation()
            await activeModel.cleanup()
        }
    }

    @ViewBuilder
    private func inlineActionBar(snapshot: ChatArtifactViewerPageSnapshot) -> some View {
        #if os(iOS)
        if showsActions {
            let policy = ChatArtifactActionVisibilityPolicy(inlineState: snapshot.state)
            if !policy.actions.isEmpty {
                ChatArtifactActionBar(
                    actions: policy.actions,
                    style: .compact,
                    disabledActions: [],
                    isRunning: snapshot.fileActionState.isRunning,
                    onAction: { action in performInlineAction(action, snapshot: snapshot) }
                )
                .padding(12)
            }
        }
        #endif
    }

    #if os(iOS)
    private func performInlineAction(
        _ action: ChatArtifactAction,
        snapshot: ChatArtifactViewerPageSnapshot
    ) {
        switch action {
        case .share:
            Task { await pageModel.prepareShare(loader: loader) }
        case .save:
            Task { await pageModel.prepareSave(loader: loader) }
        case .copyImage:
            guard case .image(let data) = snapshot.state else { return }
            UIPasteboard.general.image = UIImage(data: data)
        case .copyContents, .copyPath:
            break
        }
    }

    private var fileActionPresentationBinding: Binding<ChatArtifactFileActionPresentation?> {
        Binding(
            get: { pageModel.fileActionState.presentation },
            set: { pageModel.setFileActionPresentation($0) }
        )
    }

    private var fileActionErrorBinding: Binding<Bool> {
        Binding(
            get: { pageModel.fileActionState.showsError },
            set: { pageModel.setShowsFileActionError($0) }
        )
    }
    #endif

    @MainActor
    private func model(for path: String) -> ChatArtifactViewerPageModel {
        guard pageModel.path != path else { return pageModel }
        let model = ChatArtifactViewerPageModel(
            path: path,
            textPreferences: ChatArtifactTextPreferences(defaults: .standard)
        )
        pageModel = model
        return model
    }

    /// Keeps cleanup structured under the path-keyed SwiftUI task after loading ends.
    private func waitForViewerTaskCancellation() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        for await _ in stream {}
    }
}
