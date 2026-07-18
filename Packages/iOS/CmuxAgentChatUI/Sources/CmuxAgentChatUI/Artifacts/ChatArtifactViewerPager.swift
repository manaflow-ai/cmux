import CmuxAgentChat
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
                        viewerActionsMenu(snapshot: model.toolbarSnapshot)
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
            onDone: onDone
        )
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
    private func viewerActionsMenu(snapshot: ChatArtifactViewerPageSnapshot) -> some View {
        Menu {
            if snapshot.hasFileActions {
                Section {
                    fileActionButtons(snapshot: snapshot)
                }
            }
            if snapshot.shouldShowTextJumpControls {
                Section {
                    textViewerActionButtons(snapshot: snapshot)
                }
            }
            if snapshot.state == .markdown,
               snapshot.markdownPresentation.isRenderedAvailable {
                Section {
                    Picker(
                        String(
                            localized: "chat.artifact.markdown.view",
                            defaultValue: "Markdown view",
                            bundle: .module
                        ),
                        selection: markdownModeBinding
                    ) {
                        Text(String(
                            localized: "chat.artifact.markdown.raw",
                            defaultValue: "Raw",
                            bundle: .module
                        ))
                        .tag(ChatArtifactMarkdownMode.raw)
                        Text(String(
                            localized: "chat.artifact.markdown.rendered",
                            defaultValue: "Rendered",
                            bundle: .module
                        ))
                        .tag(ChatArtifactMarkdownMode.rendered)
                    }
                }
            }
        } label: {
            Label(
                String(
                    localized: "chat.artifact.viewer.actions",
                    defaultValue: "Viewer actions",
                    bundle: .module
                ),
                systemImage: "ellipsis.circle"
            )
        }
        .disabled(snapshot.fileActionState.isRunning)
    }

    @ViewBuilder
    private func fileActionButtons(snapshot: ChatArtifactViewerPageSnapshot) -> some View {
        Button {
            Task { await model.prepareShare(loader: loader) }
        } label: {
            Label(
                String(localized: "chat.artifact.share", defaultValue: "Share", bundle: .module),
                systemImage: "square.and.arrow.up"
            )
        }
        Button {
            Task { await model.prepareSave(loader: loader) }
        } label: {
            Label(
                String(localized: "chat.artifact.save_to_files", defaultValue: "Save to Files", bundle: .module),
                systemImage: "folder.badge.plus"
            )
        }
        if snapshot.isTextFile {
            Button {
                UIPasteboard.general.string = snapshot.renderedText
            } label: {
                Label(
                    String(localized: "chat.artifact.copy_contents", defaultValue: "Copy contents", bundle: .module),
                    systemImage: "doc.on.doc"
                )
            }
            .disabled(!snapshot.canCopyContents)
        }
        Button {
            UIPasteboard.general.string = snapshot.path
        } label: {
            Label(
                String(localized: "chat.artifact.copy_path", defaultValue: "Copy path", bundle: .module),
                systemImage: "link"
            )
        }
    }

    @ViewBuilder
    private func textViewerActionButtons(snapshot: ChatArtifactViewerPageSnapshot) -> some View {
        Button {
            withAnimation(.snappy) {
                model.toggleSearch()
            }
        } label: {
            Label(
                String(
                    localized: "chat.artifact.search.title",
                    defaultValue: "Search",
                    bundle: .module
                ),
                systemImage: "magnifyingglass"
            )
        }
        Button {
            withAnimation(.snappy) {
                model.toggleGoToLine()
            }
        } label: {
            Label(
                String(
                    localized: "chat.artifact.line.goto",
                    defaultValue: "Go to line",
                    bundle: .module
                ),
                systemImage: "text.line.first.and.arrowtriangle.forward"
            )
        }
        Button {
            model.requestTop()
        } label: {
            Label(
                String(
                    localized: "chat.artifact.jump.top",
                    defaultValue: "Top",
                    bundle: .module
                ),
                systemImage: "arrow.up.to.line"
            )
        }
        Button {
            model.requestBottom()
        } label: {
            Label(jumpToEndTitle(snapshot: snapshot), systemImage: "arrow.down.to.line")
        }
        Button {
            model.toggleLineNumbers()
        } label: {
            Label(
                String(
                    localized: "chat.artifact.line.numbers",
                    defaultValue: "Line numbers",
                    bundle: .module
                ),
                systemImage: snapshot.showsLineNumbers ? "checkmark" : "number"
            )
        }
        Button {
            model.toggleWordWrap()
        } label: {
            Label(
                String(
                    localized: "chat.artifact.wrap",
                    defaultValue: "Word wrap",
                    bundle: .module
                ),
                systemImage: snapshot.wrapsLines ? "checkmark" : "text.justify.left"
            )
        }
    }

    private var markdownModeBinding: Binding<ChatArtifactMarkdownMode> {
        Binding(
            get: { model.toolbarSnapshot.markdownPresentation.mode },
            set: { model.selectMarkdownMode($0) }
        )
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

    private func jumpToEndTitle(snapshot: ChatArtifactViewerPageSnapshot) -> String {
        switch ChatArtifactTextEndJumpTarget(reachedEOF: snapshot.textReachedEOF) {
        case .end:
            return String(
                localized: "chat.artifact.jump.end",
                defaultValue: "End",
                bundle: .module
            )
        case .latest:
            return String(
                localized: "chat.artifact.jump.latest",
                defaultValue: "Latest",
                bundle: .module
            )
        }
    }
    #endif
}
