import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#if os(iOS)
import QuickLook
#endif
#elseif canImport(AppKit)
import AppKit
#endif

/// The shared stat-driven route for every artifact entry point and folder level.
struct ChatArtifactViewerRouteView: View {
    let path: String
    let scope: ChatArtifactViewerScope
    let onDone: () -> Void
    private let textPreferences: ChatArtifactTextPreferences
    private let textLayoutKind: ChatArtifactTextLayoutKind

    @Environment(\.chatArtifactLoader) private var loader
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = ChatArtifactViewerModel()
    @State private var retryGeneration = 0
    @State private var topRequestID = 0
    @State private var bottomRequestID = 0
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @State private var searchSummary = ChatArtifactSearchSummary.empty
    @State private var previousSearchRequestID = 0
    @State private var nextSearchRequestID = 0
    @State private var showsLineNumbers = true
    @State private var isGoToLinePresented = false
    @State private var goToLineText = ""
    @State private var goToLineUTF16Offset = 0
    @State private var goToLineRequestID = 0
    @State private var wrapsLines: Bool
    @State private var textFontSize: Double

    init(
        path: String,
        scope: ChatArtifactViewerScope,
        textPreferences: ChatArtifactTextPreferences = ChatArtifactTextPreferences(
            defaults: .standard
        ),
        onDone: @escaping () -> Void
    ) {
        self.path = path
        self.scope = scope
        self.onDone = onDone
        self.textPreferences = textPreferences
        let layoutKind = ChatArtifactTextLayoutKind(path: path)
        textLayoutKind = layoutKind
        _wrapsLines = State(initialValue: textPreferences.wrapsLines(for: layoutKind))
        _textFontSize = State(initialValue: textPreferences.fontSize(for: layoutKind))
    }

    var body: some View {
        content
            .navigationTitle(displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "chat.artifact.done", defaultValue: "Done", bundle: .module)) {
                        onDone()
                    }
                }
                #if os(iOS)
                if shouldShowTextJumpControls {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            withAnimation(.snappy) {
                                if isSearchPresented {
                                    dismissSearch()
                                } else {
                                    dismissGoToLine()
                                    isSearchPresented = true
                                }
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
                        Menu {
                            Button {
                                withAnimation(.snappy) {
                                    if isGoToLinePresented {
                                        dismissGoToLine()
                                    } else {
                                        dismissSearch()
                                        isGoToLinePresented = true
                                    }
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
                                showsLineNumbers.toggle()
                            } label: {
                                Label(
                                    String(
                                        localized: "chat.artifact.line.numbers",
                                        defaultValue: "Line numbers",
                                        bundle: .module
                                    ),
                                    systemImage: showsLineNumbers ? "checkmark" : "number"
                                )
                            }
                            Button {
                                wrapsLines.toggle()
                                textPreferences.setWrapsLines(
                                    wrapsLines,
                                    for: textLayoutKind
                                )
                            } label: {
                                Label(
                                    String(
                                        localized: "chat.artifact.wrap",
                                        defaultValue: "Word wrap",
                                        bundle: .module
                                    ),
                                    systemImage: wrapsLines ? "checkmark" : "text.justify.left"
                                )
                            }
                        } label: {
                            Label(
                                String(
                                    localized: "chat.artifact.text_options",
                                    defaultValue: "Text options",
                                    bundle: .module
                                ),
                                systemImage: "textformat"
                            )
                        }
                        Button {
                            topRequestID += 1
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
                            bottomRequestID += 1
                        } label: {
                            Label(jumpToBottomTitle, systemImage: "arrow.down.to.line")
                        }
                    }
                }
                if model.state == .markdown,
                   model.markdownPresentation.isRenderedAvailable {
                    ToolbarItem(placement: .primaryAction) {
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
                        .pickerStyle(.segmented)
                    }
                }
                #endif
            }
            .task(id: "\(path)\u{0}\(retryGeneration)") {
                #if os(iOS)
                await model.load(
                    path: path,
                    loader: loader,
                    quickLookCanPreview: canQuickLookPreview
                )
                #else
                await model.load(path: path, loader: loader)
                #endif
                await waitForViewerTaskCancellation()
                await model.cleanup()
            }
    }

    /// Keeps cleanup structured under the SwiftUI page task after loading ends.
    private func waitForViewerTaskCancellation() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        for await _ in stream {}
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView(
                    value: progressValue(
                        fetched: model.fetchedBytes,
                        total: model.totalBytes
                    )
                )
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)
                Text(String(localized: "chat.artifact.loading", defaultValue: "Loading preview", bundle: .module))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if model.fetchedBytes > 0 || model.totalBytes != nil {
                    Text(
                        verbatim: progressText(
                            fetched: model.fetchedBytes,
                            total: model.totalBytes
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .folder:
            ChatArtifactFolderView(path: path, scope: scope, onDone: onDone)
        case .image(let data):
            artifactImage(data: data)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
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
            ChatArtifactQuickLookView(fileURL: fileURL, title: displayName)
                .ignoresSafeArea(.container, edges: .bottom)
            #else
            unavailableView(
                title: String(localized: "chat.artifact.preview_unavailable.title", defaultValue: "Preview unavailable", bundle: .module),
                message: String(localized: "chat.artifact.preview_unavailable.message", defaultValue: "This file can't be previewed.", bundle: .module)
            )
            #endif
        case .text:
            VStack(spacing: 0) {
                if !model.textReachedEOF {
                    streamingProgressHeader
                }
                searchBar
                goToLineBar
                highlightingStatusPill
                rawTextView
            }
        case .markdown:
            VStack(spacing: 0) {
                if !model.textReachedEOF {
                    streamingProgressHeader
                }
                if model.markdownPresentation.mode == .rendered {
                    ChatArtifactMarkdownView(markdown: model.renderedText)
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
                    fetched: model.fetchedBytes,
                    total: model.totalBytes
                )
            )
            .progressViewStyle(.linear)
            Text(verbatim: progressText(fetched: model.fetchedBytes, total: model.totalBytes))
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
            chunks: model.textChunks,
            reachedEOF: model.textReachedEOF,
            highlightDecision: model.textHighlightDecision,
            highlightTheme: colorScheme == .dark ? .dark : .light,
            searchQuery: searchQuery,
            previousSearchRequestID: previousSearchRequestID,
            nextSearchRequestID: nextSearchRequestID,
            onSearchSummaryChanged: { summary in
                searchSummary = summary
            },
            lineIndex: model.textLineIndex,
            showsLineNumbers: showsLineNumbers,
            goToLineUTF16Offset: goToLineUTF16Offset,
            goToLineRequestID: goToLineRequestID,
            wrapsLines: wrapsLines,
            fontPointSize: textFontSize,
            onFontSizeChanged: { fontSize in
                textFontSize = textPreferences.setFontSize(
                    fontSize,
                    for: textLayoutKind
                )
            },
            topRequestID: topRequestID,
            bottomRequestID: bottomRequestID
        )
        #else
        ScrollView {
            Text(model.renderedText)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        #endif
    }

    @ViewBuilder
    private var goToLineBar: some View {
        if isGoToLinePresented {
            ChatArtifactGoToLineBar(
                lineText: $goToLineText,
                onGo: goToLine,
                onClose: {
                    withAnimation(.snappy) {
                        dismissGoToLine()
                    }
                }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        if isSearchPresented {
            ChatArtifactSearchBar(
                query: $searchQuery,
                summary: searchSummary,
                isStillLoading: !model.textReachedEOF,
                onPrevious: { previousSearchRequestID += 1 },
                onNext: { nextSearchRequestID += 1 },
                onClose: {
                    withAnimation(.snappy) {
                        dismissSearch()
                    }
                }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var highlightingStatusPill: some View {
        if model.textHighlightDecision.showsHighlightingOffPill,
           let totalBytes = model.totalBytes {
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
                    retryGeneration += 1
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

    private var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private var markdownModeBinding: Binding<ChatArtifactMarkdownMode> {
        Binding(
            get: { model.markdownPresentation.mode },
            set: { mode in
                if mode == .rendered {
                    dismissSearch()
                    dismissGoToLine()
                }
                model.selectMarkdownMode(mode)
            }
        )
    }

    private func dismissSearch() {
        isSearchPresented = false
        searchQuery = ""
        searchSummary = .empty
    }

    private func dismissGoToLine() {
        isGoToLinePresented = false
        goToLineText = ""
    }

    private func goToLine(_ requestedLine: Int) {
        let line = model.textLineIndex.clampedLine(requestedLine)
        goToLineText = String(line)
        goToLineUTF16Offset = model.textLineIndex.offset(forLine: line)
        goToLineRequestID += 1
    }

    private var shouldShowTextJumpControls: Bool {
        model.state == .text
            || (model.state == .markdown && model.markdownPresentation.mode == .raw)
    }

    #if os(iOS)
    private func canQuickLookPreview(_ fileURL: URL) -> Bool {
        QLPreviewController.canPreview(
            ChatArtifactQuickLookItem(fileURL: fileURL, title: displayName)
        )
    }
    #endif

    private var jumpToBottomTitle: String {
        if model.textReachedEOF {
            return String(
                localized: "chat.artifact.jump.end",
                defaultValue: "End",
                bundle: .module
            )
        }
        return String(
            localized: "chat.artifact.jump.bottom",
            defaultValue: "Bottom",
            bundle: .module
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
