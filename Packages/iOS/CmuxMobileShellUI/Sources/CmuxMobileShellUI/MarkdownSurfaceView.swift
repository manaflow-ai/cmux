import CmuxAgentChatUI
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

/// Native iOS renderer for a Mac markdown panel.
///
/// Fetches the panel's file through the panel-scoped loader, decodes UTF-8
/// with an ISO-Latin-1 fallback, and renders the shared document-level
/// markdown view. Read-only; local links and images cannot resolve on the
/// phone in v1.
struct MarkdownSurfaceView: View {
    let surface: MobileSurfacePreview
    let path: String
    let loader: ChatArtifactLoader
    let connectionStatus: MobileMacConnectionStatus

    @State private var model = MarkdownSurfaceModel()
    @State private var retryCount = 0

    var body: some View {
        content
        // Path changes reload outright; title churn with a stable path re-runs
        // the load so a rewritten file re-renders (same-title edits stay stale
        // until the next descriptor emission — wave-0 accepted residual).
        .task(id: "\(path)\u{0}\(surface.title)\u{0}\(retryCount)") {
            await model.load(path: path, loader: loader)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
                Text(L10n.string("mobile.surface.loading", defaultValue: "Loading preview"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .loaded(let text):
            ChatArtifactEmbeddedMarkdown(markdown: text)
        case .failed(let failure):
            failureView(failure)
        }
    }

    @ViewBuilder
    private func failureView(_ failure: MarkdownSurfaceModel.Failure) -> some View {
        switch failure {
        case .fileMissing:
            MacSurfaceMessageView(
                systemImage: "doc.questionmark",
                title: L10n.string(
                    "mobile.surface.fileMissing.title",
                    defaultValue: "File not found"
                ),
                message: L10n.string(
                    "mobile.surface.fileMissing.message",
                    defaultValue: "The file is no longer available on your Mac."
                )
            )
        case .forbidden:
            MacSurfaceMessageView(
                systemImage: "lock.doc",
                title: L10n.string(
                    "mobile.surface.forbidden.title",
                    defaultValue: "Preview unavailable"
                ),
                message: L10n.string(
                    "mobile.surface.forbidden.message",
                    defaultValue: "This file isn't displayed by the selected panel."
                )
            )
        case .macUnreachable:
            MacSurfaceMessageView(
                systemImage: "wifi.exclamationmark",
                title: unreachableTitle,
                message: unreachableMessage,
                retry: { retryCount += 1 }
            )
        case .tooLarge(let actualSize, let limit):
            MacSurfaceMessageView(
                systemImage: "doc.badge.ellipsis",
                title: L10n.string(
                    "mobile.surface.tooLarge.title",
                    defaultValue: "File too large to preview"
                ),
                message: tooLargeMessage(actualSize: actualSize, limit: limit)
            )
        case .panelClosed:
            MacSurfaceMessageView(
                systemImage: "rectangle.slash",
                title: L10n.string(
                    "mobile.surface.panelClosed.title",
                    defaultValue: "Panel closed"
                ),
                message: L10n.string(
                    "mobile.surface.panelClosed.message",
                    defaultValue: "That file panel is no longer open on your Mac."
                )
            )
        case .macNeedsUpdate:
            MacSurfaceMessageView(
                systemImage: "arrow.down.circle",
                title: L10n.string(
                    "mobile.surface.macNeedsUpdate.title",
                    defaultValue: "Update cmux on your Mac"
                ),
                message: L10n.string(
                    "mobile.surface.macNeedsUpdate.message",
                    defaultValue: "The connected Mac's cmux version can't preview this file."
                )
            )
        case .transferUnavailable:
            MacSurfaceMessageView(
                systemImage: "arrow.triangle.2.circlepath",
                title: L10n.string(
                    "mobile.surface.transferUnavailable.title",
                    defaultValue: "Transfer unavailable"
                ),
                message: L10n.string(
                    "mobile.surface.transferUnavailable.message",
                    defaultValue: "File transfer is temporarily unavailable on your Mac. Try again shortly."
                ),
                retry: { retryCount += 1 }
            )
        case .loadFailed(let code):
            MacSurfaceMessageView(
                systemImage: "exclamationmark.triangle",
                title: L10n.string(
                    "mobile.surface.loadFailed.title",
                    defaultValue: "Couldn't load file"
                ),
                message: loadFailedMessage(code: code),
                retry: { retryCount += 1 }
            )
        }
    }

    private var progressValue: Double? {
        guard let total = model.totalBytes, total > 0 else { return nil }
        return Double(model.fetchedBytes) / Double(total)
    }

    /// Transport-failure copy names the side that is actually down: the
    /// phone's own dropped/reforming session reads as such, and only a
    /// healthy-looking session blames the path to the Mac.
    private var unreachableTitle: String {
        switch connectionStatus {
        case .connected:
            L10n.string("mobile.surface.macUnreachable.title", defaultValue: "Mac unreachable")
        case .reconnecting:
            L10n.string("mobile.surface.reconnecting.title", defaultValue: "Reconnecting\u{2026}")
        case .unavailable:
            L10n.string("mobile.surface.disconnected.title", defaultValue: "Not connected")
        }
    }

    private var unreachableMessage: String {
        switch connectionStatus {
        case .connected:
            L10n.string(
                "mobile.surface.macUnreachable.message",
                defaultValue: "Check the connection to your Mac and try again."
            )
        case .reconnecting:
            L10n.string(
                "mobile.surface.reconnecting.message",
                defaultValue: "This phone's connection to the Mac dropped and is coming back. Retry in a moment."
            )
        case .unavailable:
            L10n.string(
                "mobile.surface.disconnected.message",
                defaultValue: "This phone isn't connected to the Mac right now. Reconnect, then retry."
            )
        }
    }

    private func loadFailedMessage(code: String?) -> String {
        let base = L10n.string(
            "mobile.surface.loadFailed.message",
            defaultValue: "Something went wrong loading this file."
        )
        guard let code, !code.isEmpty else { return base }
        return base + " (\(code))"
    }

    private func tooLargeMessage(actualSize: Int64?, limit: Int64) -> String {
        let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
        guard let actualSize else {
            let format = L10n.string(
                "mobile.surface.tooLarge.limitFormat",
                defaultValue: "This preview is limited to %@."
            )
            return String.localizedStringWithFormat(format, limitText)
        }
        let actualText = ByteCountFormatter.string(fromByteCount: actualSize, countStyle: .file)
        let format = L10n.string(
            "mobile.surface.tooLarge.messageFormat",
            defaultValue: "This file is %1$@; previews are limited to %2$@."
        )
        return String.localizedStringWithFormat(format, actualText, limitText)
    }
}
