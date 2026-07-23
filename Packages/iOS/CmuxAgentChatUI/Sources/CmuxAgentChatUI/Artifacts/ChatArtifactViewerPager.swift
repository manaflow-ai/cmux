import CmuxAgentChat
import CmuxMobileSupport
import CmuxMobileToast
import SwiftUI

#if os(iOS)
import QuickLook
import UIKit
#endif

/// Owns path-stable viewer pages and the destination's only navigation toolbar.
struct ChatArtifactViewerPager: View {
    let initialPath: String
    let scope: ChatArtifactViewerScope
    let swipeOrder: ChatArtifactGallerySwipeOrder
    let onDone: () -> Void

    @Environment(ToastCenter.self) private var toasts
    @Environment(\.chatArtifactLoader) private var loader
    @State private var model: ChatArtifactViewerPagerModel
    @State private var zoomedPath: String?

    init(
        initialPath: String,
        scope: ChatArtifactViewerScope,
        swipeOrder: ChatArtifactGallerySwipeOrder,
        onDone: @escaping () -> Void
    ) {
        self.initialPath = initialPath
        self.scope = scope
        self.swipeOrder = swipeOrder
        self.onDone = onDone
        _model = State(initialValue: ChatArtifactViewerPagerModel(
            initialPath: initialPath,
            swipeOrder: swipeOrder,
            textPreferences: ChatArtifactTextPreferences(defaults: .standard)
        ))
    }

    @ViewBuilder
    var body: some View {
        pagerContent
            .navigationTitle(model.toolbarSnapshot.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.toolbarSnapshot.hasViewerActions {
                        ChatArtifactViewerActionsMenu(
                            value: ChatArtifactViewerActionsMenuValue(
                                snapshot: model.toolbarSnapshot,
                                loaderScope: loader.scope,
                                loaderSupportsArtifacts: loader.supportsArtifacts,
                                loaderSupportsDirectoryBrowsing: loader.supportsDirectoryBrowsing
                            ),
                            actions: viewerActionsMenuActions
                        )
                        .equatable()
                    }
                    doneButton
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    doneButton
                }
                #endif
            }
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
            .onChange(of: initialPath) { _, newPath in
                model.update(initialPath: newPath, swipeOrder: swipeOrder)
            }
            .onChange(of: swipeOrder) { _, newOrder in
                model.update(swipeOrder: newOrder)
            }
    }

    @ViewBuilder
    private var pagerContent: some View {
        #if os(iOS)
        if model.usesPaging {
            ChatArtifactPageViewController(
                pages: model.pageModels.map(hostedPage),
                selectedPath: selectionBinding,
                isPagingEnabled: zoomedPath == nil
            )
        } else {
            viewer(snapshot: model.toolbarSnapshot)
                .id(model.toolbarSnapshot.path)
        }
        #else
        viewer(snapshot: model.toolbarSnapshot)
            .id(model.toolbarSnapshot.path)
        #endif
    }

    #if os(iOS)
    private func hostedPage(model: ChatArtifactViewerPageModel) -> ChatArtifactViewerHostedPage {
        ChatArtifactViewerHostedPage(
            model: model,
            scope: scope,
            loader: loader,
            onImageMinimumZoomChanged: { path, isAtMinimum in
                if isAtMinimum {
                    if zoomedPath == path {
                        zoomedPath = nil
                    }
                } else {
                    zoomedPath = path
                }
            },
            onImageAction: { action, snapshot in
                performFileAction(action, snapshot: snapshot)
            },
            onDone: onDone
        )
    }
    #endif

    private func viewer(snapshot: ChatArtifactViewerPageSnapshot) -> some View {
        ChatArtifactViewerRouteView(
            snapshot: snapshot,
            scope: scope,
            actions: model.actions(
                for: snapshot.path,
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
            ),
            onImageMinimumZoomChanged: { isAtMinimum in
                if isAtMinimum {
                    if zoomedPath == snapshot.path {
                        zoomedPath = nil
                    }
                } else {
                    zoomedPath = snapshot.path
                }
            },
            onImageAction: imageActionPerformer(for: snapshot),
            onDone: onDone
        )
    }

    private func imageActionPerformer(
        for snapshot: ChatArtifactViewerPageSnapshot
    ) -> (@MainActor (ChatArtifactAction) -> Void)? {
        #if os(iOS)
        { action in performFileAction(action, snapshot: snapshot) }
        #else
        nil
        #endif
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { model.selectedPath },
            set: { model.select(path: $0) }
        )
    }

    private var doneButton: some View {
        Button(String(localized: "chat.artifact.done", defaultValue: "Done", bundle: .module)) {
            onDone()
        }
    }

    #if os(iOS)
    private var viewerActionsMenuActions: ChatArtifactViewerActionsMenuActions {
        ChatArtifactViewerActionsMenuActions(
            prepareShare: { path in
                Task { await model.prepareShare(for: path, loader: loader) }
            },
            prepareSave: { path in
                Task { await model.prepareSave(for: path, loader: loader) }
            },
            toggleSearch: model.toggleSearch,
            toggleGoToLine: model.toggleGoToLine,
            requestTop: model.requestTop,
            requestBottom: model.requestBottom,
            toggleLineNumbers: model.toggleLineNumbers,
            toggleWordWrap: model.toggleWordWrap,
            selectMarkdownMode: model.selectMarkdownMode,
            notifyCopied: { toasts.present(.copied()) },
            notifyPathCopied: {
                toasts.present(.copied(L10n.string("mobile.toast.pathCopied", defaultValue: "Path copied")))
            },
            performFileAction: performFileAction
        )
    }

    private func performFileAction(
        _ action: ChatArtifactAction,
        snapshot: ChatArtifactViewerPageSnapshot
    ) {
        switch action {
        case .share:
            Task { await model.prepareShare(for: snapshot.path, loader: loader) }
        case .save:
            Task { await model.prepareSave(for: snapshot.path, loader: loader) }
        case .copyImage:
            guard case .image(let data) = snapshot.state else { return }
            UIPasteboard.general.image = UIImage(data: data)
            toasts.present(.copied())
        case .copyContents:
            UIPasteboard.general.string = snapshot.renderedText
            toasts.present(.copied())
        case .copyPath:
            UIPasteboard.general.string = snapshot.path
            toasts.present(.copied(L10n.string("mobile.toast.pathCopied", defaultValue: "Path copied")))
        }
    }

    private var fileActionPresentationBinding: Binding<ChatArtifactFileActionPresentation?> {
        let path = model.toolbarSnapshot.path
        return Binding(
            get: {
                model.toolbarSnapshot.path == path
                    ? model.toolbarSnapshot.fileActionState.presentation
                    : nil
            },
            set: { model.setFileActionPresentation($0, for: path) }
        )
    }

    private var fileActionErrorBinding: Binding<Bool> {
        let path = model.toolbarSnapshot.path
        return Binding(
            get: {
                model.toolbarSnapshot.path == path
                    && model.toolbarSnapshot.fileActionState.showsError
            },
            set: { model.setShowsFileActionError($0, for: path) }
        )
    }

    #endif
}
