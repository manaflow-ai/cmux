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

    @Environment(\.chatArtifactLoader) private var loader
    @State private var model = ChatArtifactViewerModel()
    @State private var retryGeneration = 0
    @State private var topRequestID = 0
    @State private var bottomRequestID = 0

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
            }
            .onDisappear {
                Task { await model.cleanup() }
            }
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
            set: { model.selectMarkdownMode($0) }
        )
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
