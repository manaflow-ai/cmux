#if os(iOS)
import SwiftUI
import UIKit

struct ChatArtifactViewerActionsMenu: View, Equatable {
    let value: ChatArtifactViewerActionsMenuValue
    let actions: ChatArtifactViewerActionsMenuActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    private var snapshot: ChatArtifactViewerPageSnapshot { value.snapshot }

    var body: some View {
        Menu {
            if snapshot.hasFileActions {
                Section {
                    fileActionButtons
                }
            }
            if snapshot.shouldShowTextJumpControls {
                Section {
                    textViewerActionButtons
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
                        selection: Binding(
                            get: { snapshot.markdownPresentation.mode },
                            set: { actions.selectMarkdownMode(snapshot.path, $0) }
                        )
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
    private var fileActionButtons: some View {
        let policy = ChatArtifactActionVisibilityPolicy(
            viewerHasFileActions: snapshot.hasFileActions,
            isTextFile: snapshot.isTextFile,
            isImage: snapshot.isImage
        )
        ChatArtifactActionBar(
            actions: policy.actions,
            style: .menu,
            disabledActions: snapshot.canCopyContents ? [] : [.copyContents],
            isRunning: snapshot.fileActionState.isRunning,
            onAction: { action in actions.performFileAction(action, snapshot) }
        )
    }

    @ViewBuilder
    private var textViewerActionButtons: some View {
        Button {
            withAnimation(.snappy) {
                actions.toggleSearch(snapshot.path)
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
                actions.toggleGoToLine(snapshot.path)
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
            actions.requestTop(snapshot.path)
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
            actions.requestBottom(snapshot.path)
        } label: {
            Label(jumpToEndTitle, systemImage: "arrow.down.to.line")
        }
        Button {
            actions.toggleLineNumbers(snapshot.path)
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
            actions.toggleWordWrap(snapshot.path)
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

    private var jumpToEndTitle: String {
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
}
#endif
