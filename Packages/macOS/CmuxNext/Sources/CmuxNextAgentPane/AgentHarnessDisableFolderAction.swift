public import CmuxNextActions
import Foundation

/// `agent.harness.disableFolder`: withdraws a harness for the chats in a folder
/// (`_acpmux/harness_disable {folder, id}`, the undo of the Enable harness step; the CLI's
/// `cmux harness disable ID --folder DIR`). The folder is `path` when named, else the focused tab's.
@MainActor
public struct AgentHarnessDisableFolderAction {
    public static let id: ActionID = "agent.harness.disableFolder"

    private let disable: @MainActor (_ id: String, _ folder: String) async throws -> Void
    private let focusedFolder: @MainActor (ActionInvocation) -> String?
    private let failure: @MainActor (any Error) -> String

    public init(disable: @escaping @MainActor (_ id: String, _ folder: String) async throws -> Void,
                focusedFolder: @escaping @MainActor (ActionInvocation) -> String?,
                failure: @escaping @MainActor (any Error) -> String) {
        self.disable = disable
        self.focusedFolder = focusedFolder
        self.failure = failure
    }

    public func bind(into registry: ActionRegistry) {
        let (disable, focusedFolder, failure) = (disable, focusedFolder, failure)
        registry.bindEffect(Self.id, effect: { invocation in
            func named(_ key: String) -> String? {
                invocation.arguments[key]?.stringValue?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
            guard let id = named("id") else {
                return .refused(Self.text("agentHarness.disableFolder.needsAgent", "Name the agent with --arg id=<agent>."))
            }
            guard let folder = named("path") ?? focusedFolder(invocation), folder.hasPrefix("/") else {
                return .refused(Self.text("agentHarness.disableFolder.needsFolder", "Name the folder with --arg path=/absolute/folder."))
            }
            // action-wait-allow: acpmux forgets the folder's confirmations; nothing local can stand in for its answer
            return .waiting(.externalProcess) {
                do {
                    try await disable(id, folder)
                    return nil
                } catch {
                    return ActionWorkFailure(refusal: .unavailable, reason: failure(error))
                }
            }
        })
    }

    private static func text(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, bundle: .localizedModule)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
