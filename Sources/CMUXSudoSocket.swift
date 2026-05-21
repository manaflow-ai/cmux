import Darwin
import Foundation

enum CMUXSudoJSONValue: Sendable {
    case string(String)
    case int(Int)
    case null

    var any: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .null: return NSNull()
        }
    }
}

struct CMUXSudoSocketResponse: Sendable {
    let ok: Bool
    let payload: [String: CMUXSudoJSONValue]
    let code: String?
    let message: String?
    let data: [String: CMUXSudoJSONValue]?

    static func ok(_ payload: [String: CMUXSudoJSONValue]) -> CMUXSudoSocketResponse {
        .init(ok: true, payload: payload, code: nil, message: nil, data: nil)
    }

    static func err(
        code: String,
        message: String,
        data: [String: CMUXSudoJSONValue]? = nil
    ) -> CMUXSudoSocketResponse {
        .init(ok: false, payload: [:], code: code, message: message, data: data)
    }
}

final class CMUXSudoPendingRequestStore: @unchecked Sendable {
    static let shared = CMUXSudoPendingRequestStore()

    struct Access: Sendable {
        let pid: pid_t
        let uid: uid_t
        let workspaceID: UUID
        let surfaceID: UUID

        func matches(peerIdentity: CMUXSocketPeerIdentity) -> Bool {
            peerIdentity.pid == pid && peerIdentity.uid == uid
        }
    }

    private enum State {
        case pending(Access)
        case finished(Access, CMUXSudoSocketResponse)
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]

    func begin(_ requestID: String, access: Access) {
        lock.lock()
        states[requestID] = .pending(access)
        lock.unlock()
    }

    func finish(_ requestID: String, response: CMUXSudoSocketResponse) {
        lock.lock()
        switch states[requestID] {
        case .pending(let access), .finished(let access, _):
            states[requestID] = .finished(access, response)
        case .none:
            break
        }
        lock.unlock()
    }

    func state(for requestID: String, peerIdentity: CMUXSocketPeerIdentity) -> CMUXSudoPendingState {
        lock.lock()
        defer { lock.unlock() }
        guard let state = states[requestID] else { return .missing }
        switch state {
        case .pending(let access):
            guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
            return .pending
        case .finished(let access, let response):
            guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
            states.removeValue(forKey: requestID)
            return .finished(response)
        }
    }

#if DEBUG
    func reset() {
        lock.lock()
        states.removeAll()
        lock.unlock()
    }
#endif
}

enum CMUXSudoPendingState: Sendable {
    case missing
    case forbidden
    case pending
    case finished(CMUXSudoSocketResponse)
}

extension TerminalController {
    nonisolated func v2SudoRequestOnSocketWorker(params: [String: Any]) -> V2CallResult {
        let parsed = CMUXSudoCommandRequest.parse(params: params)
        guard case .success(let request) = parsed else {
            let message: String
            if case .failure(let error) = parsed {
                message = error.message
            } else {
                message = String(localized: "sudo.error.invalidRequest", defaultValue: "invalid sudo request")
            }
            return .err(code: "invalid_params", message: message, data: nil)
        }

        let peerIdentity = Self.currentSocketPeerIdentity()
        let validation = CMUXSudoCallerValidator.validate(
            request: request,
            peerIdentity: peerIdentity,
            isDescendant: { [weak self] pid in
#if DEBUG
                if let override = CMUXSudoTestHooks.isDescendantOverride {
                    return override(pid)
                }
#endif
                return self?.isDescendant(pid) ?? false
            },
            processArguments: { pid in
#if DEBUG
                if let override = CMUXSudoTestHooks.processArgumentsOverride {
                    return override(pid)
                }
#endif
                return CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: Int(pid))
            },
            surfaceExists: { [weak self] workspaceID, surfaceID in
#if DEBUG
                if let override = CMUXSudoTestHooks.surfaceExistsOverride {
                    return override(workspaceID, surfaceID)
                }
#endif
                return self?.v2SudoSurfaceExists(workspaceID: workspaceID, surfaceID: surfaceID) ?? false
            }
        )
        let auditLogURL = sudoAuditLogURL()

        guard validation.allowed else {
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: request,
                    result: "rejected",
                    exitCode: nil,
                    errorCode: "access_denied",
                    message: validation.reason
                ),
                logURL: auditLogURL
            )
            return .err(
                code: "access_denied",
                message: validation.reason ?? String(localized: "sudo.error.rejected", defaultValue: "sudo request was rejected"),
                data: nil
            )
        }

        do {
            try CMUXSudoAuditLogger.ensureWritable(logURL: auditLogURL)
        } catch {
            return .err(
                code: "audit_unavailable",
                message: String(
                    localized: "sudo.error.auditUnavailable",
                    defaultValue: "sudo audit log is not writable. No command was run."
                ),
                data: nil
            )
        }

        CMUXSudoPendingRequestStore.shared.begin(
            request.requestID,
            access: .init(
                pid: request.callerPID,
                uid: request.callerUID,
                workspaceID: request.workspaceID,
                surfaceID: request.surfaceID
            )
        )
        Task { [weak self] in
            let response: CMUXSudoSocketResponse
            if let self {
                response = await self.performSudoRequest(request: request, auditLogURL: auditLogURL)
            } else {
                response = .err(
                    code: "app_unavailable",
                    message: String(localized: "sudo.error.helperFailed", defaultValue: "sudo helper failed")
                )
            }
            CMUXSudoPendingRequestStore.shared.finish(request.requestID, response: response)
        }

        return .ok([
            "status": "pending",
            "request_id": request.requestID,
            "audit_log": auditLogURL.path,
        ])
    }

    nonisolated func v2SudoResultOnSocketWorker(params: [String: Any]) -> V2CallResult {
        guard let rawRequestID = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: String(localized: "sudo.error.invalidRequest", defaultValue: "invalid sudo request"),
                data: nil
            )
        }
        let requestID = rawRequestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestID.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "sudo.error.invalidRequest", defaultValue: "invalid sudo request"),
                data: nil
            )
        }

        switch CMUXSudoPendingRequestStore.shared.state(
            for: requestID,
            peerIdentity: Self.currentSocketPeerIdentity()
        ) {
        case .missing:
            return .err(
                code: "not_found",
                message: String(localized: "sudo.error.resultNotFound", defaultValue: "sudo request result was not found"),
                data: nil
            )
        case .forbidden:
            return .err(
                code: "access_denied",
                message: String(
                    localized: "sudo.error.resultAccessDenied",
                    defaultValue: "sudo request result belongs to another process"
                ),
                data: nil
            )
        case .pending:
            return .ok([
                "status": "pending",
                "request_id": requestID,
            ])
        case .finished(let response):
            return response.toV2CallResult()
        }
    }

    private nonisolated func performSudoRequest(
        request: CMUXSudoCommandRequest,
        auditLogURL: URL
    ) async -> CMUXSudoSocketResponse {
        let approval = await CMUXSudoApprovalPresenter.requestApproval(request)
        guard approval.approved else {
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: request,
                    result: "denied",
                    exitCode: nil,
                    errorCode: "authentication_denied",
                    message: approval.reason
                ),
                logURL: auditLogURL
            )
            return .err(
                code: "authentication_denied",
                message: approval.reason ?? String(localized: "sudo.error.denied", defaultValue: "sudo request was denied")
            )
        }

        let envelope: CMUXSudoSignedHelperEnvelope
        do {
            envelope = try CMUXSudoHelperClient.signedEnvelope(for: request)
        } catch {
            cmuxDebugLog("sudo.signing.failed error=\(String(describing: error))")
            return .err(
                code: "signing_failed",
                message: String(
                    localized: "sudo.error.signingFailed",
                    defaultValue: "Failed to prepare sudo helper request. Restart cmux and try again."
                )
            )
        }

        let execution = CMUXSudoHelperClient.execute(envelope)
        _ = try? CMUXSudoAuditLogger.append(
            auditRecord(
                request: request,
                result: execution.status,
                exitCode: execution.exitCode,
                errorCode: execution.errorCode,
                message: execution.message
            ),
            logURL: auditLogURL
        )

        guard execution.status == "completed" else {
            return .err(
                code: execution.errorCode ?? "helper_error",
                message: String(localized: "sudo.error.helperFailed", defaultValue: "sudo helper failed"),
                data: [
                    "status": .string(execution.status),
                    "exit_code": execution.exitCode.map { .int(Int($0)) } ?? .null,
                ]
            )
        }

        return .ok([
            "status": .string(execution.status),
            "exit_code": .int(Int(execution.exitCode ?? 0)),
            "stdout": execution.stdout.map { .string($0) } ?? .null,
            "stderr": execution.stderr.map { .string($0) } ?? .null,
            "audit_log": .string(auditLogURL.path),
        ])
    }

    private nonisolated func sudoAuditLogURL() -> URL {
#if DEBUG
        if let override = CMUXSudoTestHooks.auditLogURLOverride {
            return override
        }
#endif
        return CMUXSudoAuditLogger.defaultLogURL
    }

    private nonisolated func v2SudoSurfaceExists(workspaceID: UUID, surfaceID: UUID) -> Bool {
        v2MainSync {
            guard let app = AppDelegate.shared else { return false }
            for summary in app.listMainWindowSummaries() {
                guard let tabManager = app.tabManagerFor(windowId: summary.windowId),
                      let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                    continue
                }
                if workspace.terminalPanel(for: surfaceID) != nil {
                    return true
                }
            }
            return false
        }
    }

    private nonisolated func auditRecord(
        request: CMUXSudoCommandRequest,
        result: String,
        exitCode: Int32?,
        errorCode: String?,
        message: String?
    ) -> CMUXSudoAuditRecord {
        CMUXSudoAuditRecord(
            requestID: request.requestID,
            timestamp: Date(),
            workspaceID: request.workspaceID,
            surfaceID: request.surfaceID,
            requesterPID: request.callerPID,
            requesterUID: request.callerUID,
            command: request.argv,
            commandDisplay: request.displayCommand,
            result: result,
            exitCode: exitCode,
            errorCode: errorCode,
            message: message
        )
    }
}

private extension CMUXSudoSocketResponse {
    func toV2CallResult() -> TerminalController.V2CallResult {
        if ok {
            return .ok(payload.mapValues { $0.any })
        }
        return .err(
            code: code ?? "sudo_error",
            message: message ?? String(localized: "sudo.error.helperFailed", defaultValue: "sudo helper failed"),
            data: data?.mapValues { $0.any }
        )
    }
}
