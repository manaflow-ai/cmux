import CmuxAgentChat
import Foundation

/// Localized copy and retry guidance for one typed artifact failure.
public struct ChatArtifactFailurePresentation: Equatable, Sendable {
    /// Short failure title suitable for an unavailable view or alert.
    public let title: String
    /// Specific explanation and remediation for the failure.
    public let message: String
    /// SF Symbol describing the failure category.
    public let systemImage: String
    /// Whether repeating the same operation can reasonably recover.
    public let allowsRetry: Bool

    /// Creates presentation copy without discarding the underlying failure reason.
    ///
    /// - Parameters:
    ///   - error: Typed failure from the host, transport, transfer, or local store.
    ///   - scope: Authorization context used to explain forbidden paths accurately.
    ///   - actualSize: Stat-reported size used by the too-large message.
    public init(
        error: ChatArtifactError,
        scope: ChatArtifactViewerScope,
        actualSize: Int64? = nil
    ) {
        switch error {
        case .unsupported:
            self = Self.failure(
                title: ("chat.artifact.failure.unsupported.title", "File previews unavailable"),
                message: ("chat.artifact.failure.unsupported.message", "This Mac doesn't support file previews. Update cmux on the Mac."),
                systemImage: "arrow.up.circle",
                allowsRetry: false
            )
        case .invalidParams:
            self = Self.failure(
                title: ("chat.artifact.failure.invalid_request.title", "Invalid file request"),
                message: ("chat.artifact.failure.invalid_request.message", "The file request was invalid. Update cmux on both devices."),
                systemImage: "exclamationmark.triangle",
                allowsRetry: false
            )
        case .sessionNotFound:
            self = Self.failure(
                title: ("chat.artifact.session_missing.title", "Session not found"),
                message: ("chat.artifact.session_missing.message", "The chat session for this file is no longer available."),
                systemImage: "exclamationmark.bubble",
                allowsRetry: false
            )
        case .sessionUnavailable:
            self = Self.failure(
                title: ("chat.artifact.failure.session_unavailable.title", "Session unavailable"),
                message: ("chat.artifact.failure.session_unavailable.message", "The session exists, but its file history couldn't be read on the Mac."),
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                allowsRetry: true
            )
        case .terminalNotFound:
            self = Self.failure(
                title: ("chat.artifact.failure.terminal_missing.title", "Terminal not found"),
                message: ("chat.artifact.failure.terminal_missing.message", "The terminal that authorized this file is no longer available."),
                systemImage: "terminal",
                allowsRetry: false
            )
        case .workspaceNotFound:
            self = Self.failure(
                title: ("chat.artifact.failure.workspace_missing.title", "Workspace not found"),
                message: ("chat.artifact.failure.workspace_missing.message", "The workspace for this file is no longer available."),
                systemImage: "rectangle.stack.badge.minus",
                allowsRetry: false
            )
        case .notRepository:
            self = Self.failure(
                title: ("chat.artifact.failure.not_repository.title", "Repository unavailable"),
                message: ("chat.artifact.failure.not_repository.message", "The workspace folder is no longer a Git repository."),
                systemImage: "arrow.triangle.branch",
                allowsRetry: false
            )
        case .forbidden:
            let message: Copy = switch scope {
            case .chat:
                ("chat.artifact.forbidden.message", "This file was not referenced by the conversation.")
            case .terminal:
                ("chat.artifact.forbidden.terminal_message", "This file isn't visible in the current terminal view.")
            case .panel:
                ("chat.artifact.forbidden.panel_message", "That file panel is no longer open on your Mac.")
            case .workspaceChanges:
                ("chat.artifact.failure.forbidden.workspace_message", "This file is no longer part of the workspace changes.")
            }
            self = Self.failure(
                title: ("chat.artifact.forbidden.title", "Preview unavailable"),
                message: message,
                systemImage: "lock",
                allowsRetry: false
            )
        case .fileNotFound:
            self = Self.failure(
                title: ("chat.artifact.file_missing.title", "File not found"),
                message: ("chat.artifact.file_missing.message", "The file is no longer available on your Mac."),
                systemImage: "doc.badge.minus",
                allowsRetry: false
            )
        case .permissionDenied:
            self = Self.failure(
                title: ("chat.artifact.failure.permission.title", "Permission denied"),
                message: ("chat.artifact.failure.permission.message", "cmux found the file, but the Mac doesn't allow cmux to read it. Check the file's permissions."),
                systemImage: "lock.trianglebadge.exclamationmark",
                allowsRetry: false
            )
        case .notDirectory:
            self = Self.failure(
                title: ("chat.artifact.failure.not_directory.title", "Not a folder"),
                message: ("chat.artifact.failure.not_directory.message", "This path is a file, not a folder."),
                systemImage: "folder.badge.questionmark",
                allowsRetry: false
            )
        case .notRegularFile:
            self = Self.failure(
                title: ("chat.artifact.failure.not_regular_file.title", "Not a regular file"),
                message: ("chat.artifact.failure.not_regular_file.message", "This path is a folder or special filesystem item, so its bytes can't be previewed."),
                systemImage: "doc.badge.ellipsis",
                allowsRetry: false
            )
        case .fileReadFailed:
            self = Self.failure(
                title: ("chat.artifact.failure.read_failed.title", "Couldn't read file"),
                message: ("chat.artifact.failure.read_failed.message", "The Mac found the file but couldn't read its metadata or contents. Try again."),
                systemImage: "doc.badge.exclamationmark",
                allowsRetry: true
            )
        case .fileChanged:
            self = Self.failure(
                title: ("chat.artifact.failure.file_changed.title", "File changed"),
                message: ("chat.artifact.failure.file_changed.message", "The file changed while it was loading. Try again to load the latest version."),
                systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard",
                allowsRetry: true
            )
        case .unsupportedMedia:
            self = Self.failure(
                title: ("chat.artifact.preview_unavailable.title", "Preview unavailable"),
                message: ("chat.artifact.preview_unavailable.message", "This file can't be previewed."),
                systemImage: "doc",
                allowsRetry: false
            )
        case .corruptMedia:
            self = Self.failure(
                title: ("chat.artifact.failure.corrupt_media.title", "File is damaged"),
                message: ("chat.artifact.failure.corrupt_media.message", "The file type is supported, but its media data couldn't be decoded."),
                systemImage: "doc.badge.exclamationmark",
                allowsRetry: false
            )
        case .previewFailed:
            self = Self.failure(
                title: ("chat.artifact.failure.preview_failed.title", "Couldn't create preview"),
                message: ("chat.artifact.failure.preview_failed.message", "The file was read, but cmux couldn't create its preview. Try again."),
                systemImage: "eye.slash",
                allowsRetry: true
            )
        case .unavailable:
            self = Self.failure(
                title: ("chat.artifact.failure.service_unavailable.title", "File service unavailable"),
                message: ("chat.artifact.failure.service_unavailable.message", "File transfer is temporarily unavailable on the Mac. Try again."),
                systemImage: "wrench.and.screwdriver",
                allowsRetry: true
            )
        case .invalidResponse:
            self = Self.failure(
                title: ("chat.artifact.failure.invalid_response.title", "Invalid file response"),
                message: ("chat.artifact.failure.invalid_response.message", "The Mac sent inconsistent file data. Try again, then update cmux if it continues."),
                systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                allowsRetry: true
            )
        case .transferInterrupted:
            self = Self.failure(
                title: ("chat.artifact.failure.transfer_interrupted.title", "Transfer interrupted"),
                message: ("chat.artifact.failure.transfer_interrupted.message", "The file transfer stopped before all bytes arrived. Try again."),
                systemImage: "arrow.down.circle.dotted",
                allowsRetry: true
            )
        case .requestTimedOut:
            self = Self.failure(
                title: ("chat.artifact.failure.timeout.title", "Request timed out"),
                message: ("chat.artifact.failure.timeout.message", "The file request didn't complete in time. Try again."),
                systemImage: "clock.badge.exclamationmark",
                allowsRetry: true
            )
        case .connectionRecovering:
            self = Self.failure(
                title: ("chat.artifact.failure.reconnecting.title", "Reconnecting to Mac"),
                message: ("chat.artifact.failure.reconnecting.message", "A connection attempt is already in progress. Try again in a moment."),
                systemImage: "arrow.triangle.2.circlepath",
                allowsRetry: true
            )
        case .connectionNeedsRestart:
            self = Self.failure(
                title: ("chat.artifact.failure.restart.title", "Restart required"),
                message: ("chat.artifact.failure.restart.message", "Connection cleanup is stuck. Restart cmux on this device, reconnect, and try again."),
                systemImage: "arrow.clockwise.circle",
                allowsRetry: false
            )
        case .secureConnectionRequired:
            self = Self.failure(
                title: ("chat.artifact.failure.secure_connection.title", "Secure connection required"),
                message: ("chat.artifact.failure.secure_connection.message", "This route can't securely transfer Mac files. Reconnect using a paired secure route."),
                systemImage: "lock.shield",
                allowsRetry: false
            )
        case .authenticationExpired:
            self = Self.failure(
                title: ("chat.artifact.failure.authentication_expired.title", "Pairing expired"),
                message: ("chat.artifact.failure.authentication_expired.message", "Reconnect to the Mac to refresh authentication, then try again."),
                systemImage: "key.slash",
                allowsRetry: false
            )
        case .authorizationFailed:
            self = Self.failure(
                title: ("chat.artifact.failure.authorization.title", "Connection not authorized"),
                message: ("chat.artifact.failure.authorization.message", "This device isn't authorized to read files from the Mac. Pair it again."),
                systemImage: "person.badge.shield.checkmark",
                allowsRetry: false
            )
        case .accountMismatch:
            self = Self.failure(
                title: ("chat.artifact.failure.account_mismatch.title", "Account mismatch"),
                message: ("chat.artifact.failure.account_mismatch.message", "This device and the Mac are signed in to different cmux accounts."),
                systemImage: "person.2.badge.minus",
                allowsRetry: false
            )
        case .localStorageFull:
            self = Self.failure(
                title: ("chat.artifact.failure.storage_full.title", "iPhone storage full"),
                message: ("chat.artifact.failure.storage_full.message", "Free some storage on this device, then try again."),
                systemImage: "internaldrive.badge.exclamationmark",
                allowsRetry: false
            )
        case .localStorageUnavailable:
            self = Self.failure(
                title: ("chat.artifact.failure.local_storage.title", "Local storage unavailable"),
                message: ("chat.artifact.failure.local_storage.message", "The file arrived, but cmux couldn't create or read its temporary file on this device. Try again."),
                systemImage: "internaldrive.badge.questionmark",
                allowsRetry: true
            )
        case .loadFailed:
            self = Self.failure(
                title: ("chat.artifact.load_failed.title", "Couldn't load file"),
                message: ("chat.artifact.load_failed.message", "The file couldn't be loaded. Try again."),
                systemImage: "exclamationmark.triangle",
                allowsRetry: true
            )
        case .macUnreachable:
            self = Self.failure(
                title: ("chat.artifact.mac_unreachable.title", "Mac unreachable"),
                message: ("chat.artifact.mac_unreachable.message", "Check the connection to your Mac and try again."),
                systemImage: "wifi.exclamationmark",
                allowsRetry: true
            )
        case .tooLarge(let limitBytes):
            self = Self(
                title: Self.localized("chat.artifact.too_large.title", defaultValue: "File too large to preview"),
                message: Self.tooLargeMessage(actualSize: actualSize, limit: limitBytes),
                systemImage: "doc.badge.ellipsis",
                allowsRetry: false
            )
        case .unknown(let code):
            // The Mac replied, so this copy must not blame connectivity.
            self = Self(
                title: Self.localized("chat.artifact.failure.unknown.title", defaultValue: "Unrecognized error"),
                message: Self.unknownMessage(code: code),
                systemImage: "questionmark.circle",
                allowsRetry: false
            )
        }
    }

    private typealias Copy = (key: StaticString, value: String.LocalizationValue)

    private init(title: String, message: String, systemImage: String, allowsRetry: Bool) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.allowsRetry = allowsRetry
    }

    private static func failure(
        title: Copy,
        message: Copy,
        systemImage: String,
        allowsRetry: Bool
    ) -> Self {
        Self(
            title: localized(title.key, defaultValue: title.value),
            message: localized(message.key, defaultValue: message.value),
            systemImage: systemImage,
            allowsRetry: allowsRetry
        )
    }

    private static func localized(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }

    private static func tooLargeMessage(actualSize: Int64?, limit: Int64) -> String {
        let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
        guard let actualSize else {
            let format = localized(
                "chat.artifact.too_large.limit_message",
                defaultValue: "This preview is limited to %@."
            )
            return String.localizedStringWithFormat(format, limitText)
        }
        let format = localized(
            "chat.artifact.too_large.message",
            defaultValue: "This file is %@; previews are limited to %@."
        )
        return String.localizedStringWithFormat(
            format,
            ByteCountFormatter.string(fromByteCount: actualSize, countStyle: .file),
            limitText
        )
    }

    private static func unknownMessage(code: String?) -> String {
        guard let code else {
            return localized(
                "chat.artifact.failure.unknown.message",
                defaultValue: "The Mac reported an error this app doesn't recognize. Update cmux on both devices."
            )
        }
        let format = localized(
            "chat.artifact.failure.unknown.message_with_code",
            defaultValue: "The Mac reported an error this app doesn't recognize (%@). Update cmux on both devices."
        )
        return String.localizedStringWithFormat(format, code)
    }
}
