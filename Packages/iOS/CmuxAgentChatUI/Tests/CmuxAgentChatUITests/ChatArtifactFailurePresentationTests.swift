import CmuxAgentChat
import Testing

@testable import CmuxAgentChatUI

@Suite
struct ChatArtifactFailurePresentationTests {
    @Test
    func everyFailureHasSpecificCopyAndRetryGuidance() {
        let unreachable = ChatArtifactFailurePresentation(
            error: .macUnreachable,
            scope: .chat
        )
        let cases: [(error: ChatArtifactError, title: String, allowsRetry: Bool)] = [
            (.unsupported, "File previews unavailable", false),
            (.invalidParams, "Invalid file request", false),
            (.sessionNotFound, "Session not found", false),
            (.sessionUnavailable, "Session unavailable", true),
            (.terminalNotFound, "Terminal not found", false),
            (.workspaceNotFound, "Workspace not found", false),
            (.notRepository, "Repository unavailable", false),
            (.forbidden, "Preview unavailable", false),
            (.fileNotFound, "File not found", false),
            (.permissionDenied, "Permission denied", false),
            (.notDirectory, "Not a folder", false),
            (.notRegularFile, "Not a regular file", false),
            (.fileReadFailed, "Couldn't read file", true),
            (.fileChanged, "File changed", true),
            (.unsupportedMedia, "Preview unavailable", false),
            (.corruptMedia, "File is damaged", false),
            (.previewFailed, "Couldn't create preview", true),
            (.unavailable, "File service unavailable", true),
            (.invalidResponse, "Invalid file response", true),
            (.transferInterrupted, "Transfer interrupted", true),
            (.requestTimedOut, "Request timed out", true),
            (.connectionRecovering, "Reconnecting to Mac", true),
            (.connectionNeedsRestart, "Restart required", false),
            (.secureConnectionRequired, "Secure connection required", false),
            (.authenticationExpired, "Pairing expired", false),
            (.authorizationFailed, "Connection not authorized", false),
            (.accountMismatch, "Account mismatch", false),
            (.localStorageFull, "iPhone storage full", false),
            (.localStorageUnavailable, "Local storage unavailable", true),
            (.loadFailed, "Couldn't load file", true),
            (.tooLarge(limitBytes: 1_024), "File too large to preview", false),
            (.unknown(code: "artifact_rev_gone"), "Unrecognized error", false),
        ]

        #expect(unreachable.title == "Mac unreachable")
        #expect(unreachable.allowsRetry)
        for item in cases {
            let presentation = ChatArtifactFailurePresentation(
                error: item.error,
                scope: .chat,
                actualSize: 2_048
            )
            #expect(presentation.title == item.title)
            #expect(presentation.allowsRetry == item.allowsRetry)
            #expect(!presentation.message.isEmpty)
            #expect(!presentation.systemImage.isEmpty)
            #expect(presentation.title != unreachable.title)
            #expect(presentation.message != unreachable.message)
        }
    }

    @Test
    func unknownCopySurfacesTheCodeWithoutBlamingConnectivity() {
        let coded = ChatArtifactFailurePresentation(error: .unknown(code: "artifact_rev_gone"), scope: .chat)
        let uncoded = ChatArtifactFailurePresentation(error: .unknown(code: nil), scope: .chat)

        // The Mac replied, so the copy must not send the user to check connectivity.
        #expect(coded.message.contains("artifact_rev_gone"))
        #expect(!coded.message.contains("Check the connection"))
        #expect(!uncoded.message.contains("Check the connection"))
        #expect(!uncoded.message.isEmpty)
    }

    @Test
    func forbiddenCopyMatchesAuthorizationScope() {
        let chat = ChatArtifactFailurePresentation(error: .forbidden, scope: .chat)
        let terminal = ChatArtifactFailurePresentation(error: .forbidden, scope: .terminal)
        let changes = ChatArtifactFailurePresentation(error: .forbidden, scope: .workspaceChanges)

        #expect(chat.message != terminal.message)
        #expect(terminal.message != changes.message)
        #expect(changes.message != chat.message)
    }

}
