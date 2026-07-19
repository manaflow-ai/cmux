import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct ChatArtifactViewerSheet: View {
    let path: String
    let scope: ChatArtifactViewerScope

    @Environment(\.chatArtifactLoader) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading(fetched: 0, total: nil)

    public init(path: String, scope: ChatArtifactViewerScope = .chat) {
        self.path = path
        self.scope = scope
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(displayName)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "chat.artifact.done", defaultValue: "Done", bundle: .module)) {
                            dismiss()
                        }
                    }
                }
        }
        .task(id: path) {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading(let fetched, let total):
            VStack(spacing: 12) {
                ProgressView(value: progressValue(fetched: fetched, total: total))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
                Text(String(localized: "chat.artifact.loading", defaultValue: "Loading preview", bundle: .module))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if fetched > 0 || total != nil {
                    Text(verbatim: progressText(fetched: fetched, total: total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .image(let data):
            artifactImage(data: data)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        case .text(let text):
            #if canImport(UIKit)
            ChatArtifactTextView(text: text)
            #else
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            #endif
        case .binary(let stat):
            unavailableView(
                title: String(localized: "chat.artifact.preview_unavailable.title", defaultValue: "Preview unavailable", bundle: .module),
                message: String(localized: "chat.artifact.preview_unavailable.message", defaultValue: "This file can't be previewed.", bundle: .module),
                detail: formattedSize(stat.size)
            )
        case .tooLarge(let limit):
            unavailableView(
                title: String(localized: "chat.artifact.too_large.title", defaultValue: "File too large to preview", bundle: .module),
                message: tooLargeMessage(limit: limit)
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

    private func load() async {
        await MainActor.run {
            state = .loading(fetched: 0, total: nil)
        }
        do {
            let stat = try await loader.stat(path: path)
            guard !stat.isDirectory else {
                await MainActor.run { state = .binary(stat: stat) }
                return
            }
            guard stat.size <= ChatArtifactTransferPolicy.defaultPolicy.maxPreviewBytes else {
                await MainActor.run {
                    state = .tooLarge(limit: ChatArtifactTransferPolicy.defaultPolicy.maxPreviewBytes)
                }
                return
            }
            let data = try await loader.fetch(path: path) { fetched, total in
                Task { @MainActor in
                    state = .loading(fetched: fetched, total: total)
                }
            }
            guard !Task.isCancelled else { return }
            switch stat.kind {
            case .image:
                await MainActor.run { state = .image(data: data) }
            case .text:
                if let text = String(data: data, encoding: .utf8) {
                    await MainActor.run { state = .text(text: text) }
                } else {
                    await MainActor.run { state = .binary(stat: stat) }
                }
            case .binary, .directory:
                await MainActor.run { state = .binary(stat: stat) }
            }
        } catch {
            await MainActor.run {
                state = LoadState(error: error)
            }
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
                    Task { await load() }
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

    private func tooLargeMessage(limit: Int64) -> String {
        let format = String(
            localized: "chat.artifact.too_large.message",
            defaultValue: "This preview is limited to %@.",
            bundle: .module
        )
        return String.localizedStringWithFormat(format, formattedSize(limit))
    }

    private enum LoadState: Equatable {
        case loading(fetched: Int64, total: Int64?)
        case image(data: Data)
        case text(text: String)
        case binary(stat: ChatArtifactStat)
        case tooLarge(limit: Int64)
        case unsupportedMedia
        case fileMissing
        case macUnreachable
        case forbidden

        init(error: any Error) {
            guard let artifactError = error as? ChatArtifactError else {
                self = .macUnreachable
                return
            }
            switch artifactError {
            case .fileNotFound:
                self = .fileMissing
            case .forbidden:
                self = .forbidden
            case .macUnreachable, .unavailable, .unsupported, .sessionNotFound, .invalidParams:
                self = .macUnreachable
            case .unsupportedMedia:
                self = .unsupportedMedia
            case .tooLarge(let limitBytes):
                self = .tooLarge(limit: limitBytes)
            }
        }
    }
}

struct ChatArtifactPathSelection: Identifiable, Equatable {
    let path: String
    var id: String { path }
}
