import CmuxConversation
import CmuxConversationHost
import CmuxControlSocket
import CmuxCore
import Foundation

extension TerminalController {
    @MainActor
    func v2MobileConversationDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        guard let service = nativeConversationService else {
            return .err(code: "unavailable", message: String(localized: "conversation.error.unavailable", defaultValue: "Tasks are not available on this Mac yet."), data: nil)
        }
        guard let rawWorkspaceID = params["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: rawWorkspaceID),
              let manager = v2ResolveTabManager(params: ["workspace_id": workspaceID.uuidString]),
              let workspace = v2ResolveWorkspace(params: ["workspace_id": workspaceID.uuidString], tabManager: manager) else {
            return .err(code: "invalid_scope", message: String(localized: "conversation.error.workspace", defaultValue: "Select an available workspace for this task."), data: nil)
        }
        do {
            let payload = try conversationPayload(params)
            let (broker, identity) = try await service.currentRuntime()
            let result: Any
            switch method {
            case "mobile.conversation.list":
                let sessions = try await broker.listSessions().filter { $0.workspaceID == workspaceID.uuidString }
                result = try conversationJSON(sessions)
            case "mobile.conversation.create":
                let requested = try JSONDecoder().decode(ConversationCreateRequest.self, from: payload)
                guard UUID(uuidString: requested.workspaceID) == workspaceID,
                      let requestID = requested.requestID, validConversationID(requestID.rawValue),
                      (requested.title?.utf8.count ?? 0) <= 512 else { throw NativeConversationError.invalidPayload }
                // Directory and destination come exclusively from the current
                // host workspace, never from the phone's serialized request.
                guard let directory = workspace.presentedCurrentDirectory,
                      directory.hasPrefix("/"), !directory.contains("\0") else {
                    throw NativeConversationError.unsupportedTarget
                }
                let target = try conversationTarget(workspace: workspace, directory: directory)
                guard service.isCurrent(identity) else { throw NativeConversationError.unauthenticated }
                result = try conversationJSON(await broker.createSession(ConversationCreateRequest(
                    requestID: requestID, provider: requested.provider, workspaceID: workspaceID.uuidString,
                    directory: directory, launchTarget: target, title: requested.title
                )))
            case "mobile.conversation.snapshot", "mobile.conversation.replay":
                let query = try JSONDecoder().decode(ConversationSessionQuery.self, from: payload)
                let snapshot = try await scopedConversationSnapshot(broker, sessionID: query.sessionID, workspaceID: workspaceID)
                if method == "mobile.conversation.snapshot" {
                    result = try conversationJSON(snapshot)
                } else {
                    result = try conversationJSON(await broker.replay(sessionID: query.sessionID, after: query.after ?? 0))
                }
            case "mobile.conversation.command":
                let command = try JSONDecoder().decode(ConversationCommandEnvelope.self, from: payload)
                guard validConversationID(command.commandID.rawValue), command.expectedGeneration != nil else {
                    throw NativeConversationError.invalidPayload
                }
                _ = try await scopedConversationSnapshot(broker, sessionID: command.sessionID, workspaceID: workspaceID)
                guard service.isCurrent(identity) else { throw NativeConversationError.unauthenticated }
                result = try conversationJSON(await broker.execute(command))
            case "mobile.conversation.receipt":
                let query = try JSONDecoder().decode(ConversationReceiptQuery.self, from: payload)
                guard validConversationID(query.commandID.rawValue) else { throw NativeConversationError.invalidPayload }
                _ = try await scopedConversationSnapshot(broker, sessionID: query.sessionID, workspaceID: workspaceID)
                result = try conversationJSON(await broker.receipt(query))
            case "mobile.conversation.artifact":
                let query = try JSONDecoder().decode(ConversationArtifactQuery.self, from: payload)
                guard validConversationID(query.artifactID), !workspace.usesRemoteDirectoryProvenance else {
                    throw NativeConversationError.unsupportedTarget
                }
                let snapshot = try await scopedConversationSnapshot(broker, sessionID: query.sessionID, workspaceID: workspaceID)
                result = try conversationJSON(await service.artifacts.chunk(query: query, snapshot: snapshot))
            default:
                return .err(code: "method_not_found", message: String(localized: "conversation.error.operation", defaultValue: "This task operation is not supported."), data: nil)
            }
            guard service.isCurrent(identity) else { throw NativeConversationError.unauthenticated }
            return .ok(["value": result])
        } catch NativeConversationError.unauthenticated {
            return .err(code: "unauthorized", message: String(localized: "conversation.error.account", defaultValue: "Sign in to the same account on both devices."), data: nil)
        } catch NativeConversationError.invalidScope {
            return .err(code: "invalid_scope", message: String(localized: "conversation.error.scope", defaultValue: "This task belongs to another workspace."), data: nil)
        } catch NativeConversationError.unsupportedTarget {
            return .err(code: "unsupported_target", message: String(localized: "conversation.error.target", defaultValue: "This workspace does not provide a supported connection for native tasks."), data: nil)
        } catch NativeConversationError.invalidPayload {
            return .err(code: "invalid_params", message: String(localized: "conversation.error.payload", defaultValue: "The task request is incomplete or too large."), data: nil)
        } catch is DecodingError {
            return .err(code: "invalid_params", message: String(localized: "conversation.error.decode", defaultValue: "The task request could not be read."), data: nil)
        } catch let error as ConversationProviderError {
            // Provider errors are normalized by the adapter; raw stderr and
            // credentials are never serialized into a mobile error.
            return .err(code: "provider_error", message: error.description, data: nil)
        } catch {
            return .err(code: "conversation_unavailable", message: String(localized: "conversation.error.load", defaultValue: "The task could not be loaded. Reconnect to check its status."), data: nil)
        }
    }

    @MainActor
    private func scopedConversationSnapshot(
        _ broker: ConversationBroker, sessionID: ConversationID, workspaceID: UUID
    ) async throws -> ConversationSnapshot {
        guard validConversationID(sessionID.rawValue) else { throw NativeConversationError.invalidPayload }
        let snapshot = try await broker.snapshot(sessionID: sessionID)
        guard snapshot.session.workspaceID == workspaceID.uuidString else { throw NativeConversationError.invalidScope }
        return snapshot
    }

    @MainActor
    private func conversationTarget(workspace: Workspace, directory: String) throws -> ConversationLaunchTarget {
        guard workspace.usesRemoteDirectoryProvenance else { return .local(directory: directory) }
        guard let config = workspace.remoteConfiguration, config.transport == .ssh,
              !config.destination.isEmpty, !config.destination.hasPrefix("-"),
              !config.destination.contains("\0") else { throw NativeConversationError.unsupportedTarget }
        var arguments: [String] = ["-o", "BatchMode=yes"]
        if let port = config.port { arguments += ["-p", String(port)] }
        if let identity = config.identityFile { arguments += ["-i", identity] }
        for option in config.sshOptions { arguments += ["-o", option] }
        // An explicit agent override must be honored; silently inheriting a
        // different agent could authenticate to the wrong remote principal.
        if config.agentSocketPathOverrideIsSet {
            arguments += ["-o", "IdentityAgent=\(config.agentSocketPath ?? "none")"]
        }
        return .ssh(host: config.destination, directory: directory, arguments: arguments)
    }

    private func conversationPayload(_ params: [String: Any]) throws -> Data {
        guard let value = params["payload"] as? [String: Any] else { throw NativeConversationError.invalidPayload }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 1_048_576 else { throw NativeConversationError.invalidPayload }
        return data
    }

    private func conversationJSON<Value: Encodable>(_ value: Value) throws -> Any {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8_388_608 else { throw NativeConversationError.invalidPayload }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func validConversationID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
    }
}

extension TerminalController {
    /// Handles one bounded, idempotent terminal-composer attachment chunk.
    /// This lane remains independent from the native agent conversation
    /// protocol; it preserves the existing terminal file-paste behavior.
    func v2MobileTaskAttachmentUpload(params: [String: Any]) -> V2CallResult {
        guard let operationIDString = v2RawString(params, "operation_id"),
              let operationID = UUID(uuidString: operationIDString),
              let uploadIDString = v2RawString(params, "upload_id"),
              let uploadID = UUID(uuidString: uploadIDString),
              let fileName = v2RawString(params, "file_name"),
              let totalBytes = v2Int(params, "total_bytes"),
              let offset = v2Int(params, "offset"),
              let dataBase64 = v2RawString(params, "data_b64"),
              let isLast = params["last"] as? Bool else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid attachment upload parameters",
                data: nil
            )
        }
        let store = MobileTaskAttachmentStore(
            rootURL: MobileTaskAttachmentStore.defaultRootURL(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ),
            now: Date(),
            fileManager: FileManager.default
        )
        do {
            let result = try store.upload(MobileTaskAttachmentUploadRequest(
                operationID: operationID,
                uploadID: uploadID,
                fileName: fileName,
                totalBytes: totalBytes,
                offset: offset,
                dataBase64: dataBase64,
                isLast: isLast
            ))
            var payload: [String: Any] = ["received_bytes": result.receivedBytes]
            if let path = result.path { payload["path"] = path }
            return .ok(payload)
        } catch let error as MobileTaskAttachmentStoreError {
            return .err(code: error.code, message: error.message, data: nil)
        } catch {
            return .err(
                code: "internal_error",
                message: "Could not store task attachment",
                data: nil
            )
        }
    }
}
