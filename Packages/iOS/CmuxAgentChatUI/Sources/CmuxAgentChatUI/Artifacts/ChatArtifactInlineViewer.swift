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
        let sourceIdentity: String?
    }

    private let path: String
    private let actionHost: ChatArtifactInlineActionHost?
    @Environment(\.chatArtifactLoader) private var loader
    @State private var pageModel: ChatArtifactViewerPageModel

    /// Creates an inline preview for one artifact path.
    /// - Parameters:
    ///   - path: Artifact path passed to the environment's ``ChatArtifactLoader``.
    ///   - actionHost: Optional bridge that lets an ancestor toolbar invoke loaded-preview actions.
    public init(path: String, actionHost: ChatArtifactInlineActionHost? = nil) {
        self.path = path
        self.actionHost = actionHost
        _pageModel = State(initialValue: ChatArtifactViewerPageModel(
            path: path,
            textPreferences: ChatArtifactTextPreferences(defaults: .standard)
        ))
    }

    public var body: some View {
        let snapshot = pageModel.snapshot
        let actionDescriptor = inlineActionDescriptor(snapshot: snapshot)
        ChatArtifactViewerRouteView(
            snapshot: snapshot,
            scope: viewerScope,
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
            onImageAction: imageActionPerformer,
            onDone: {}
        )
        .clipped()
        #if os(iOS)
        .preference(
            key: ChatArtifactInlineActionsPreferenceKey.self,
            value: actionDescriptor
        )
        .task(id: actionDescriptor?.id) {
            guard let actionHost, let actionDescriptor else { return }
            let registrationID = actionHost.register(descriptor: actionDescriptor) { action in
                performInlineAction(action)
            }
            defer { actionHost.clear(registrationID: registrationID) }
            await waitForViewerTaskCancellation()
        }
        .chatArtifactFileActionPresentation(fileActionPresentationBinding)
        .alert(
            fileActionFailurePresentation.title,
            isPresented: fileActionErrorBinding
        ) {
            Button(String(localized: "chat.artifact.ok", defaultValue: "OK", bundle: .module)) {}
        } message: {
            Text(fileActionFailurePresentation.message)
        }
        #endif
        .task(id: LoadIdentity(
            path: path,
            retryGeneration: snapshot.retryGeneration,
            sourceIdentity: loader.sourceIdentity
        )) {
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

    private func inlineActionDescriptor(
        snapshot: ChatArtifactViewerPageSnapshot
    ) -> ChatArtifactInlineActionDescriptor? {
        #if os(iOS)
        let policy = ChatArtifactActionVisibilityPolicy(inlineState: snapshot.state)
        guard let stateIdentity = policy.inlineStateIdentity, !policy.actions.isEmpty else {
            return nil
        }
        return ChatArtifactInlineActionDescriptor(
            id: "\(snapshot.path)\u{0}\(stateIdentity)",
            actions: policy.actions,
            isRunning: snapshot.fileActionState.isRunning
        )
        #else
        nil
        #endif
    }

    #if os(iOS)
    private func performInlineAction(_ action: ChatArtifactAction) {
        switch action {
        case .share:
            Task { await pageModel.prepareShare(loader: loader) }
        case .save:
            Task { await pageModel.prepareSave(loader: loader) }
        case .copyImage:
            guard case .image(let data) = pageModel.snapshot.state else { return }
            UIPasteboard.general.image = UIImage(data: data)
            loader.recordDiagnostic(.artifactCopied)
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

    private var fileActionFailurePresentation: ChatArtifactFailurePresentation {
        ChatArtifactFailurePresentation(
            error: pageModel.fileActionState.failure ?? .loadFailed,
            scope: viewerScope
        )
    }
    #endif

    private var viewerScope: ChatArtifactViewerScope {
        switch loader.scope {
        case .chat:
            .chat
        case .terminal:
            .terminal
        case .panel:
            .panel
        case .workspaceChanges:
            .workspaceChanges
        case .unsupported:
            .terminal
        }
    }

    private var imageActionPerformer: (@MainActor (ChatArtifactAction) -> Void)? {
        #if os(iOS)
        performInlineAction
        #else
        nil
        #endif
    }

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
