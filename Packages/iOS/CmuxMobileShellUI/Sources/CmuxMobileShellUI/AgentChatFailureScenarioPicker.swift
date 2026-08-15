#if DEBUG
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileSupport
import Foundation
import SwiftUI

/// A deterministic artifact failure that can be selected from the debug chat
/// demo. Each case drives the same viewer entry point as a real Mac response.
enum AgentChatFailureScenario: String, CaseIterable, Hashable, Identifiable, Sendable {
    case unsupported
    case invalidParams = "invalid_params"
    case sessionNotFound = "session_not_found"
    case sessionUnavailable = "session_unavailable"
    case terminalNotFound = "terminal_not_found"
    case workspaceNotFound = "workspace_not_found"
    case notRepository = "not_a_repo"
    case forbidden
    case fileNotFound = "file_not_found"
    case permissionDenied = "permission_denied"
    case notDirectory = "not_directory"
    case notRegularFile = "not_regular_file"
    case fileReadFailed = "file_read_failed"
    case fileChanged = "file_changed"
    case unsupportedMedia = "unsupported_media"
    case corruptMedia = "corrupt_media"
    case previewFailed = "preview_failed"
    case unavailable
    case invalidResponse = "invalid_response"
    case transferInterrupted = "transfer_interrupted"
    case requestTimedOut = "request_timed_out"
    case connectionRecovering = "connection_recovering"
    case connectionNeedsRestart = "connection_needs_restart"
    case secureConnectionRequired = "secure_connection_required"
    case authenticationExpired = "authentication_expired"
    case authorizationFailed = "authorization_failed"
    case accountMismatch = "account_mismatch"
    case localStorageFull = "local_storage_full"
    case localStorageUnavailable = "local_storage_unavailable"
    case loadFailed = "load_failed"
    case macUnreachable = "mac_unreachable"
    case tooLarge = "too_large"

    var id: String { rawValue }

    /// The typed error the real artifact viewer receives from its loader.
    var error: ChatArtifactError {
        switch self {
        case .unsupported: .unsupported
        case .invalidParams: .invalidParams
        case .sessionNotFound: .sessionNotFound
        case .sessionUnavailable: .sessionUnavailable
        case .terminalNotFound: .terminalNotFound
        case .workspaceNotFound: .workspaceNotFound
        case .notRepository: .notRepository
        case .forbidden: .forbidden
        case .fileNotFound: .fileNotFound
        case .permissionDenied: .permissionDenied
        case .notDirectory: .notDirectory
        case .notRegularFile: .notRegularFile
        case .fileReadFailed: .fileReadFailed
        case .fileChanged: .fileChanged
        case .unsupportedMedia: .unsupportedMedia
        case .corruptMedia: .corruptMedia
        case .previewFailed: .previewFailed
        case .unavailable: .unavailable
        case .invalidResponse: .invalidResponse
        case .transferInterrupted: .transferInterrupted
        case .requestTimedOut: .requestTimedOut
        case .connectionRecovering: .connectionRecovering
        case .connectionNeedsRestart: .connectionNeedsRestart
        case .secureConnectionRequired: .secureConnectionRequired
        case .authenticationExpired: .authenticationExpired
        case .authorizationFailed: .authorizationFailed
        case .accountMismatch: .accountMismatch
        case .localStorageFull: .localStorageFull
        case .localStorageUnavailable: .localStorageUnavailable
        case .loadFailed: .loadFailed
        case .macUnreachable: .macUnreachable
        case .tooLarge: .tooLarge(limitBytes: ChatArtifactTransferPolicy.defaultPolicy.maxPreviewBytes)
        }
    }

    /// Copy rendered by the real unavailable viewer for this failure.
    var presentation: ChatArtifactFailurePresentation {
        ChatArtifactFailurePresentation(
            error: error,
            scope: .chat,
            actualSize: self == .tooLarge ? ChatArtifactTransferPolicy.defaultPolicy.maxPreviewBytes + 1 : nil
        )
    }

    var title: String { presentation.title }
    var message: String { presentation.message }

    var category: AgentChatFailureScenarioCategory {
        switch self {
        case .unsupported,
             .invalidParams,
             .sessionNotFound,
             .sessionUnavailable,
             .terminalNotFound,
             .workspaceNotFound,
             .notRepository,
             .forbidden,
             .loadFailed:
            .request
        case .fileNotFound,
             .permissionDenied,
             .notDirectory,
             .notRegularFile,
             .fileReadFailed,
             .fileChanged:
            .filesystem
        case .unsupportedMedia,
             .corruptMedia,
             .previewFailed,
             .tooLarge:
            .media
        case .unavailable,
             .invalidResponse,
             .transferInterrupted,
             .requestTimedOut:
            .transfer
        case .connectionRecovering,
             .connectionNeedsRestart,
             .secureConnectionRequired,
             .authenticationExpired,
             .authorizationFailed,
             .accountMismatch,
             .macUnreachable:
            .connection
        case .localStorageFull,
             .localStorageUnavailable:
            .storage
        }
    }

    /// A loader that fails at stat time, preserving the selected typed reason.
    var loader: ChatArtifactLoader {
        let failure = error
        return ChatArtifactLoader(
            supportsArtifacts: true,
            scope: .chat(sessionID: "agent-chat-demo-\(rawValue)"),
            stat: { _ in
                throw failure
            }
        )
    }
}

enum AgentChatFailureScenarioCategory: String, CaseIterable, Identifiable, Sendable {
    case request
    case filesystem
    case media
    case transfer
    case connection
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .request:
            L10n.string(
                "mobile.settings.agentChat.failureScenarios.category.request",
                defaultValue: "Request and scope"
            )
        case .filesystem:
            L10n.string(
                "mobile.settings.agentChat.failureScenarios.category.filesystem",
                defaultValue: "File system"
            )
        case .media:
            L10n.string(
                "mobile.settings.agentChat.failureScenarios.category.media",
                defaultValue: "Media and preview"
            )
        case .transfer:
            L10n.string(
                "mobile.settings.agentChat.failureScenarios.category.transfer",
                defaultValue: "Transfer"
            )
        case .connection:
            L10n.string(
                "mobile.settings.agentChat.failureScenarios.category.connection",
                defaultValue: "Connection and auth"
            )
        case .storage:
            L10n.string(
                "mobile.settings.agentChat.failureScenarios.category.storage",
                defaultValue: "Device storage"
            )
        }
    }
}

/// Phone-friendly selector for the complete typed artifact failure matrix.
struct AgentChatFailureScenarioPicker: View {
    @Binding private var selection: AgentChatFailureScenario
    @Environment(\.dismiss) private var dismiss

    init(selection: Binding<AgentChatFailureScenario>) {
        _selection = selection
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        L10n.string(
                            "mobile.settings.agentChat.failureScenarios.instructions",
                            defaultValue: "Choose a case, then tap the CI attachment in the conversation to see its message."
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AgentChatFailureScenarioInstructions")
                }

                ForEach(AgentChatFailureScenarioCategory.allCases) { category in
                    Section {
                        ForEach(AgentChatFailureScenario.allCases.filter { $0.category == category }) { scenario in
                            Button {
                                selection = scenario
                                dismiss()
                            } label: {
                                scenarioRow(scenario)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("AgentChatFailureScenario-\(scenario.rawValue)")
                            .accessibilityValue(Text(verbatim: scenario.message))
                        }
                    } header: {
                        Text(verbatim: category.title)
                    }
                }
            }
            .navigationTitle(
                L10n.string(
                    "mobile.settings.agentChat.failureScenarios.title",
                    defaultValue: "Artifact failure scenarios"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        L10n.string(
                            "mobile.settings.agentChat.failureScenarios.done",
                            defaultValue: "Done"
                        )
                    ) {
                        dismiss()
                    }
                    .accessibilityIdentifier("AgentChatFailureScenarioPickerDone")
                }
            }
        }
        .accessibilityIdentifier("AgentChatFailureScenarioPicker")
    }

    @ViewBuilder
    private func scenarioRow(_ scenario: AgentChatFailureScenario) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: scenario.presentation.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: scenario.title)
                    .foregroundStyle(.primary)
                Text(verbatim: scenario.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if selection == scenario {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
#endif
