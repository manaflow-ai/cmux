import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders one immutable artifact page snapshot without contributing navigation chrome.
struct ChatArtifactViewerRouteView: View {
    let snapshot: ChatArtifactViewerPageSnapshot
    let scope: ChatArtifactViewerScope
    let actions: ChatArtifactViewerPageActions
    let onDone: () -> Void
    let onImageMinimumZoomChanged: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var presentation = ChatArtifactViewerPresentationCoordinator()

    init(
        snapshot: ChatArtifactViewerPageSnapshot,
        scope: ChatArtifactViewerScope,
        actions: ChatArtifactViewerPageActions,
        onImageMinimumZoomChanged: @escaping (Bool) -> Void = { _ in },
        onDone: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.scope = scope
        self.actions = actions
        self.onDone = onDone
        self.onImageMinimumZoomChanged = onImageMinimumZoomChanged
    }

    var body: some View {
        content
            .onAppear {
                presentation.present()
            }
            .onDisappear {
                presentation.dismiss()
            }
            .task(id: "\(path)\u{0}\(snapshot.retryGeneration)\u{0}\(presentation.generation)") {
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
                    onMinimumZoomChanged: onImageMinimumZoomChanged
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
        case .tooLarge(let actualSize, let limit):
            unavailableView(
                title: String(localized: "chat.artifact.too_large.title", defaultValue: "File too large to preview", bundle: .module),
                message: tooLargeMessage(actualSize: actualSize, limit: limit)
            )
        case .unsupportedMedia:
            unavailableView(
                title: String(localized: "chat.artifact.preview_unavailable.title", defaultValue: "Preview unavailable", bundle: .module),
                message: String(localized: "chat.artifact.preview_unavailable.message", defaultValue: "This file can't be previewed.", bundle: .module),
                detail: nil
            )
        case .fileMissing:
            unavailableView(
                title: String(localized: "chat.artifact.file_missing.title", defaultValue: "File not found", bundle: .module),
                message: String(localized: "chat.artifact.file_missing.message", defaultValue: "The file is no longer available on your Mac.", bundle: .module),
                retry: false
            )
        case .macUnreachable:
            unavailableView(
                title: String(localized: "chat.artifact.mac_unreachable.title", defaultValue: "Mac unreachable", bundle: .module),
                message: String(localized: "chat.artifact.mac_unreachable.message", defaultValue: "Check the connection to your Mac and try again.", bundle: .module),
                retry: true
            )
        case .forbidden:
            unavailableView(
                title: String(localized: "chat.artifact.forbidden.title", defaultValue: "Preview unavailable", bundle: .module),
                message: forbiddenMessage,
                retry: false
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

    @ViewBuilder
    private func artifactImage(data: Data) -> some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
        } else {
            Color.clear
        }
        #elseif canImport(AppKit)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
        } else {
            Color.clear
        }
        #else
        Color.clear
        #endif
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

    private var forbiddenMessage: String {
        switch scope {
        case .chat:
            String(
                localized: "chat.artifact.forbidden.message",
                defaultValue: "This file was not referenced by the conversation.",
                bundle: .module
            )
        case .terminal:
            String(
                localized: "chat.artifact.forbidden.terminal_message",
                defaultValue: "This file isn't visible in the current terminal view.",
                bundle: .module
            )
        }
    }

    private func progressValue(fetched: Int64, total: Int64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return Double(fetched) / Double(total)
    }

    private func progressText(fetched: Int64, total: Int64?) -> String {
        if let total {
            return "\(formattedSize(fetched)) / \(formattedSize(total))"
        }
        return formattedSize(fetched)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func tooLargeMessage(actualSize: Int64?, limit: Int64) -> String {
        guard let actualSize else {
            let format = String(
                localized: "chat.artifact.too_large.limit_message",
                defaultValue: "This preview is limited to %@.",
                bundle: .module
            )
            return String.localizedStringWithFormat(format, formattedSize(limit))
        }
        let format = String(
            localized: "chat.artifact.too_large.message",
            defaultValue: "This file is %@; previews are limited to %@.",
            bundle: .module
        )
        return String.localizedStringWithFormat(
            format,
            formattedSize(actualSize),
            formattedSize(limit)
        )
    }
}

extension ChatArtifactStat {
    /// Whether this artifact routes to the recursive folder browser.
    func showsFolder(supportsDirectoryBrowsing: Bool) -> Bool {
        isDirectory && supportsDirectoryBrowsing
    }
}
