import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders one immutable artifact page snapshot without contributing navigation chrome.
struct ChatArtifactViewerRouteView: View {
    private struct LoadIdentity: Hashable {
        let path: String
        let retryGeneration: Int
        let presentationGeneration: Int
        let sourceIdentity: String?
    }

    let snapshot: ChatArtifactViewerPageSnapshot
    let scope: ChatArtifactViewerScope
    let actions: ChatArtifactViewerPageActions
    /// The host's live session state, so transport-failure copy can identify
    /// whether the phone is disconnected or the Mac is unreachable.
    var connectionHint: ChatArtifactConnectionHint = .connected
    let onDone: () -> Void
    let onImageMinimumZoomChanged: (Bool) -> Void
    let onImageAction: (@MainActor (ChatArtifactAction) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatArtifactLoader) private var loader
    @State private var presentation = ChatArtifactViewerPresentationCoordinator()

    init(
        snapshot: ChatArtifactViewerPageSnapshot,
        scope: ChatArtifactViewerScope,
        actions: ChatArtifactViewerPageActions,
        connectionHint: ChatArtifactConnectionHint = .connected,
        onImageMinimumZoomChanged: @escaping (Bool) -> Void = { _ in },
        onImageAction: (@MainActor (ChatArtifactAction) -> Void)? = nil,
        onDone: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.scope = scope
        self.actions = actions
        self.connectionHint = connectionHint
        self.onDone = onDone
        self.onImageMinimumZoomChanged = onImageMinimumZoomChanged
        self.onImageAction = onImageAction
    }

    var body: some View {
        content
            .onAppear {
                presentation.present()
            }
            .onDisappear {
                presentation.dismiss()
            }
            .task(id: LoadIdentity(
                path: path,
                retryGeneration: snapshot.retryGeneration,
                presentationGeneration: presentation.generation,
                sourceIdentity: loader.sourceIdentity
            )) {
                let didStart = await presentation.loadAfterPresentation {
                    await actions.load()
                }
                guard didStart else { return }
                await waitForViewerTaskCancellation()
                await actions.cleanup()
            }
    }

    private var path: String { snapshot.path }

    /// Keeps cleanup structured under the SwiftUI page task after loading ends.
    private func waitForViewerTaskCancellation() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        for await _ in stream {}
    }

    @ViewBuilder
    private var content: some View {
        switch snapshot.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView(
                    value: progressValue(
                        fetched: snapshot.fetchedBytes,
                        total: snapshot.totalBytes
                    )
                )
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)
                Text(String(localized: "chat.artifact.loading", defaultValue: "Loading preview", bundle: .module))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if snapshot.fetchedBytes > 0 || snapshot.totalBytes != nil {
                    Text(
                        verbatim: progressText(
                            fetched: snapshot.fetchedBytes,
                            total: snapshot.totalBytes
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .folder:
            ChatArtifactFolderView(
                path: path,
                scope: scope,
                onDone: onDone
            )
        case .image(let data):
            #if os(iOS)
            if let image = UIImage(data: data) {
                ChatArtifactZoomableImageView(
                    image: image,
                    onMinimumZoomChanged: onImageMinimumZoomChanged,
                    onAction: onImageAction
                )
                .ignoresSafeArea(.container, edges: .bottom)
                .onDisappear {
                    onImageMinimumZoomChanged(true)
                }
            } else {
                Color.clear
            }
            #else
            artifactImage(data: data)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            #endif
        case .pdf(let fileURL):
            #if os(iOS)
            ChatArtifactPDFView(fileURL: fileURL)
                .ignoresSafeArea(.container, edges: .bottom)
            #else
            unavailableView(
                title: String(localized: "chat.artifact.preview_unavailable.title", defaultValue: "Preview unavailable", bundle: .module),
                message: String(localized: "chat.artifact.preview_unavailable.message", defaultValue: "This file can't be previewed.", bundle: .module)
            )
            #endif
        case .media(let fileURL):
            #if os(iOS)
            ChatArtifactMediaView(fileURL: fileURL)
                .ignoresSafeArea(.container, edges: .bottom)
            #else
            unavailableView(
                title: String(localized: "chat.artifact.preview_unavailable.title", defaultValue: "Preview unavailable", bundle: .module),
                message: String(localized: "chat.artifact.preview_unavailable.message", defaultValue: "This file can't be previewed.", bundle: .module)
            )
            #endif
        case .quickLook(let fileURL):
            #if os(iOS)
            ChatArtifactQuickLookView(fileURL: fileURL, title: snapshot.displayName)
                .ignoresSafeArea(.container, edges: .bottom)
            #else
            unavailableView(
                title: String(localized: "chat.artifact.preview_unavailable.title", defaultValue: "Preview unavailable", bundle: .module),
                message: String(localized: "chat.artifact.preview_unavailable.message", defaultValue: "This file can't be previewed.", bundle: .module)
            )
            #endif
        case .text:
            VStack(spacing: 0) {
                if !snapshot.textReachedEOF {
                    streamingProgressHeader
                }
                searchBar
                goToLineBar
                highlightingStatusPill
                rawTextView
            }
        case .markdown:
            VStack(spacing: 0) {
                if !snapshot.textReachedEOF {
                    streamingProgressHeader
                }
                if snapshot.markdownPresentation.mode == .rendered {
                    ChatArtifactMarkdownView(markdown: snapshot.renderedText)
                } else {
                    searchBar
                    goToLineBar
                    highlightingStatusPill
                    rawTextView
                }
            }
        case .binary(let stat):
            unavailableView(
                title: String(localized: "chat.artifact.preview_unavailable.title", defaultValue: "Preview unavailable", bundle: .module),
                message: String(localized: "chat.artifact.preview_unavailable.message", defaultValue: "This file can't be previewed.", bundle: .module),
                detail: formattedSize(stat.size)
            )
        case .failure(let error, let actualSize):
            let failure = ChatArtifactFailurePresentation(
                error: error,
                scope: scope,
                actualSize: actualSize
            )
            let copy = error == .macUnreachable
                ? connectionHint.unreachableCopy
                : (title: failure.title, message: failure.message)
            unavailableView(
                title: copy.title,
                message: copy.message,
                retry: failure.allowsRetry
            )
        }
    }

    private var streamingProgressHeader: some View {
        HStack(spacing: 10) {
            ProgressView(
                value: progressValue(
                    fetched: snapshot.fetchedBytes,
                    total: snapshot.totalBytes
                )
            )
            .progressViewStyle(.linear)
            Text(verbatim: progressText(fetched: snapshot.fetchedBytes, total: snapshot.totalBytes))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var rawTextView: some View {
        #if canImport(UIKit)
        ChatArtifactTextView(
            documentID: path,
            chunks: snapshot.textChunks,
            reachedEOF: snapshot.textReachedEOF,
            highlightDecision: snapshot.textHighlightDecision,
            highlightTheme: colorScheme == .dark ? .dark : .light,
            searchQuery: snapshot.searchQuery,
            previousSearchRequestID: snapshot.previousSearchRequestID,
            nextSearchRequestID: snapshot.nextSearchRequestID,
            onSearchSummaryChanged: { actions.setSearchSummary($0) },
            lineIndex: snapshot.textLineIndex,
            showsLineNumbers: snapshot.showsLineNumbers,
            goToLineUTF16Offset: snapshot.goToLineUTF16Offset,
            goToLineRequestID: snapshot.goToLineRequestID,
            wrapsLines: snapshot.wrapsLines,
            fontPointSize: snapshot.textFontSize,
            onFontSizeChanged: { actions.setFontSize($0) },
            topRequestID: snapshot.topRequestID,
            bottomRequestID: snapshot.bottomRequestID
        )
        #else
        ScrollView {
            Text(snapshot.renderedText)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        #endif
    }

    @ViewBuilder
    private var goToLineBar: some View {
        if snapshot.isGoToLinePresented {
            ChatArtifactGoToLineBar(
                lineText: goToLineTextBinding,
                onGo: { actions.goToLine($0) },
                onClose: {
                    withAnimation(.snappy) {
                        actions.dismissGoToLine()
                    }
                }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        if snapshot.isSearchPresented {
            ChatArtifactSearchBar(
                query: searchQueryBinding,
                summary: snapshot.searchSummary,
                isStillLoading: !snapshot.textReachedEOF,
                onPrevious: { actions.selectPreviousSearchResult() },
                onNext: { actions.selectNextSearchResult() },
                onClose: {
                    withAnimation(.snappy) {
                        actions.dismissSearch()
                    }
                }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var highlightingStatusPill: some View {
        if snapshot.showsHighlightingStatusPill,
           let totalBytes = snapshot.totalBytes {
            HStack {
                Spacer(minLength: 16)
                ChatArtifactHighlightingStatusPill(
                    actualBytes: totalBytes,
                    maximumBytes: ChatArtifactSyntaxHighlightPolicy.maxHighlightBytes
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func unavailableView(
        title: String,
        message: String,
        detail: String? = nil,
        retry: Bool = false
    ) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if retry {
                Button {
                    actions.retry()
                } label: {
                    Label(
                        String(localized: "chat.artifact.retry", defaultValue: "Retry", bundle: .module),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { snapshot.searchQuery },
            set: { actions.setSearchQuery($0) }
        )
    }

    private var goToLineTextBinding: Binding<String> {
        Binding(
            get: { snapshot.goToLineText },
            set: { actions.setGoToLineText($0) }
        )
    }

}
