import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileSupport
import Foundation
import SwiftUI

extension CMUXMobileRootView {
    var shouldShowAgentChatDemoPreview: Bool {
        #if os(iOS) && DEBUG
        UITestConfig.agentChatPreviewEnabled || UITestConfig.agentChatInlinePreviewEnabled
        #else
        false
        #endif
    }

    @ViewBuilder var agentChatDemoPreview: some View {
        #if os(iOS) && DEBUG
        if UITestConfig.agentChatInlinePreviewEnabled {
            AgentChatDemoScreen(
                style: .inlineWorkspace,
                artifactLoader: agentChatDemoArtifactLoader
            )
        } else if UITestConfig.agentChatPreviewEnabled {
            AgentChatDemoScreen(artifactLoader: agentChatDemoArtifactLoader)
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }

    #if os(iOS) && DEBUG
    private var agentChatDemoArtifactLoader: ChatArtifactLoader {
        let failure = UITestConfig.value(
            for: "CMUX_UITEST_AGENT_CHAT_ARTIFACT_FAILURE",
            env: ProcessInfo.processInfo.environment
        )
        let error: ChatArtifactError
        switch failure {
        case "unsupported":
            error = .unsupported
        case "invalid_params":
            error = .invalidParams
        case "session_not_found":
            error = .sessionNotFound
        case "session_unavailable":
            error = .sessionUnavailable
        case "terminal_not_found":
            error = .terminalNotFound
        case "workspace_not_found":
            error = .workspaceNotFound
        case "not_a_repo":
            error = .notRepository
        case "forbidden":
            error = .forbidden
        case "file_not_found":
            error = .fileNotFound
        case "permission_denied":
            error = .permissionDenied
        case "not_directory":
            error = .notDirectory
        case "not_regular_file":
            error = .notRegularFile
        case "read_failed":
            error = .fileReadFailed
        case "file_changed":
            error = .fileChanged
        case "unsupported_media":
            error = .unsupportedMedia
        case "corrupt_media":
            error = .corruptMedia
        case "preview_failed":
            error = .previewFailed
        case "unavailable":
            error = .unavailable
        case "invalid_response":
            error = .invalidResponse
        case "transfer_interrupted":
            error = .transferInterrupted
        case "request_timed_out":
            error = .requestTimedOut
        case "connection_recovering":
            error = .connectionRecovering
        case "connection_needs_restart":
            error = .connectionNeedsRestart
        case "secure_connection_required":
            error = .secureConnectionRequired
        case "authentication_expired":
            error = .authenticationExpired
        case "authorization_failed":
            error = .authorizationFailed
        case "account_mismatch":
            error = .accountMismatch
        case "local_storage_full":
            error = .localStorageFull
        case "local_storage_unavailable":
            error = .localStorageUnavailable
        case "load_failed":
            error = .loadFailed
        case "mac_unreachable":
            error = .macUnreachable
        case "too_large":
            error = .tooLarge(limitBytes: 1_024)
        default:
            return .unsupported()
        }
        return ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in throw error }
        )
    }
    #endif
}
