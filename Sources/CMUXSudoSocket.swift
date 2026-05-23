import Darwin
import Foundation
import os

nonisolated private let cmuxSudoSocketLogger = Logger(subsystem: "com.cmuxterm.app", category: "sudo-socket")

extension TerminalController {
    nonisolated func v2SudoRequestOnSocketWorker(params: [String: Any]) -> V2CallResult {
        let parsed = CMUXSudoCommandRequest.parse(params: params)
        let rawRequest: CMUXSudoCommandRequest
        switch parsed {
        case .success(let request):
            rawRequest = request
        case .failure(let error):
            return .err(code: error.code, message: error.message, data: nil)
        }

        let peerIdentity = Self.currentSocketPeerIdentity()
        let validation = CMUXSudoCallerValidator.validate(
            request: rawRequest,
            peerIdentity: peerIdentity,
            isDescendant: { [weak self] pid in
#if DEBUG
                if let override = CMUXSudoTestHooks.isDescendantOverride {
                    return override(pid)
                }
#endif
                return self?.isDescendant(pid) ?? false
            },
            trustedSurfaceScope: { [weak self] pid in
#if DEBUG
                if let override = CMUXSudoTestHooks.trustedSurfaceScopeOverride {
                    return override(pid)
                }
#endif
                return self?.v2SudoTrustedSurfaceScope(forPeerPID: pid)
            }
        )
        let auditLogURL = sudoAuditLogURL()

        guard validation.allowed else {
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: rawRequest,
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
        guard let peerWorkingDirectory = v2SudoWorkingDirectory(for: rawRequest.callerPID) else {
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: rawRequest,
                    result: "rejected",
                    exitCode: nil,
                    errorCode: "cwd_unavailable",
                    message: String(
                        localized: "sudo.error.cwdUnavailable",
                        defaultValue: "requesting process working directory is unavailable"
                    )
                ),
                logURL: auditLogURL
            )
            return .err(
                code: "access_denied",
                message: String(
                    localized: "sudo.error.cwdUnavailable",
                    defaultValue: "requesting process working directory is unavailable"
                ),
                data: nil
            )
        }
        let request = rawRequest.withWorkingDirectory(peerWorkingDirectory)

        guard let peerProcessStartTime = peerIdentity.processStartTime else {
            return .err(
                code: "access_denied",
                message: String(
                    localized: "sudo.error.peerProcessUnavailable",
                    defaultValue: "socket peer process identity is unavailable"
                ),
                data: nil
            )
        }
        let access = CMUXSudoPendingRequestStore.Access(
            pid: request.callerPID,
            uid: request.callerUID,
            processStartTime: peerProcessStartTime,
            workspaceID: request.workspaceID,
            surfaceID: request.surfaceID
        )
        guard CMUXSudoPendingRequestStore.shared.begin(request.requestID, access: access) else {
            return .err(
                code: "conflict",
                message: String(localized: "sudo.error.invalidRequest", defaultValue: "invalid sudo request"),
                data: nil
            )
        }
        let task = Task { [weak self] in
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
        CMUXSudoPendingRequestStore.shared.attachTask(request.requestID, task: task)

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
            peerIdentity: Self.currentSocketPeerIdentity(),
            waitUntil: Self.sudoResultWaitDeadline(params: params)
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

    nonisolated func v2SudoCancelOnSocketWorker(params: [String: Any]) -> V2CallResult {
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

        let response = CMUXSudoSocketResponse.err(
            code: "cancelled",
            message: String(localized: "cli.sudo.error.timeout", defaultValue: "sudo request timed out")
        )
        switch CMUXSudoPendingRequestStore.shared.cancel(
            requestID: requestID,
            peerIdentity: Self.currentSocketPeerIdentity(),
            response: response
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
        case .cancelled:
            return .ok([
                "status": "cancelled",
                "request_id": requestID,
            ])
        case .finished(let response):
            return response.toV2CallResult()
        }
    }

    private nonisolated static func sudoResultWaitDeadline(params: [String: Any]) -> Date? {
        guard let raw = params["wait_ms"] else { return nil }
        let milliseconds: Int?
        if let value = raw as? Int {
            milliseconds = value
        } else if let value = raw as? NSNumber {
            milliseconds = value.intValue
        } else if let value = raw as? String {
            milliseconds = Int(value)
        } else {
            milliseconds = nil
        }
        guard let milliseconds else { return nil }
        let clamped = min(max(milliseconds, 0), 30_000)
        guard clamped > 0 else { return nil }
        return Date().addingTimeInterval(Double(clamped) / 1000.0)
    }

    private nonisolated func performSudoRequest(
        request: CMUXSudoCommandRequest,
        auditLogURL: URL
    ) async -> CMUXSudoSocketResponse {
        let helperAvailability = CMUXSudoHelperClient.availability()
        guard helperAvailability.available else {
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: request,
                    result: "helper_unavailable",
                    exitCode: nil,
                    errorCode: helperAvailability.errorCode,
                    message: helperAvailability.message
                ),
                logURL: auditLogURL
            )
            return .err(
                code: sanitizedHelperErrorCode(helperAvailability.errorCode),
                message: helperAvailability.message ?? String(
                    localized: "sudo.helper.unavailable",
                    defaultValue: "The cmux sudo helper is not installed or enabled. No command was run."
                ),
                data: [
                    "status": .string("helper_unavailable"),
                    "error_code": helperAvailability.errorCode.map { .string($0) } ?? .null,
                ]
            )
        }

        let approval = await CMUXSudoApprovalPresenter.requestApproval(request)
        guard !Task.isCancelled else {
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: request,
                    result: "cancelled",
                    exitCode: nil,
                    errorCode: "cancelled",
                    message: String(localized: "cli.sudo.error.timeout", defaultValue: "sudo request timed out")
                ),
                logURL: auditLogURL
            )
            return .err(
                code: "cancelled",
                message: String(localized: "cli.sudo.error.timeout", defaultValue: "sudo request timed out")
            )
        }
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
            cmuxSudoSocketLogger.error("sudo.signing.failed error=\(String(describing: error), privacy: .private)")
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: request,
                    result: "signing_failed",
                    exitCode: nil,
                    errorCode: "signing_failed",
                    message: String(
                        localized: "sudo.error.signingFailed",
                        defaultValue: "Failed to prepare sudo helper request. Restart cmux and try again."
                    )
                ),
                logURL: auditLogURL
            )
            return .err(
                code: "signing_failed",
                message: String(
                    localized: "sudo.error.signingFailed",
                    defaultValue: "Failed to prepare sudo helper request. Restart cmux and try again."
                )
            )
        }
        guard !Task.isCancelled else {
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: request,
                    result: "cancelled",
                    exitCode: nil,
                    errorCode: "cancelled",
                    message: String(localized: "cli.sudo.error.timeout", defaultValue: "sudo request timed out")
                ),
                logURL: auditLogURL
            )
            return .err(
                code: "cancelled",
                message: String(localized: "cli.sudo.error.timeout", defaultValue: "sudo request timed out")
            )
        }

        let execution = await executeSudoHelper(envelope)
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
                code: sanitizedHelperErrorCode(execution.errorCode),
                message: execution.message ?? String(localized: "sudo.error.helperFailed", defaultValue: "sudo helper failed"),
                data: [
                    "status": .string(execution.status),
                    "exit_code": execution.exitCode.map { .int(Int($0)) } ?? .null,
                    "error_code": execution.errorCode.map { .string($0) } ?? .null,
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

    private nonisolated func executeSudoHelper(
        _ envelope: CMUXSudoSignedHelperEnvelope
    ) async -> CMUXSudoHelperExecutionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CMUXSudoHelperClient.execute(envelope))
            }
        }
    }

    private nonisolated func v2SudoTrustedSurfaceScope(forPeerPID pid: pid_t) -> CMUXSudoTrustedSurfaceScope? {
        guard pid > 0 else { return nil }
        let processSnapshot = CmuxTopProcessSnapshot.capture()
        guard let peerTTYDevice = processSnapshot.process(pid: Int(pid))?.ttyDevice else {
            return nil
        }

        return v2MainSync {
            guard let app = AppDelegate.shared else { return nil }
            var matches = Set<CMUXSudoTrustedSurfaceScope>()
            for summary in app.listMainWindowSummaries() {
                guard let tabManager = app.tabManagerFor(windowId: summary.windowId) else {
                    continue
                }
                for workspace in tabManager.tabs {
                    for panel in workspace.panels.values {
                        guard let terminalPanel = panel as? TerminalPanel,
                              let ttyName = Self.v2SudoLiveTTYName(for: terminalPanel.surface),
                              CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: ttyName) == peerTTYDevice else {
                            continue
                        }
                        matches.insert(
                            CMUXSudoTrustedSurfaceScope(
                                workspaceID: workspace.id,
                                surfaceID: terminalPanel.id
                            )
                        )
                    }
                }
            }
            return matches.count == 1 ? matches.first : nil
        }
    }

    @MainActor
    private static func v2SudoLiveTTYName(for terminalSurface: TerminalSurface) -> String? {
        guard let surface = terminalSurface.liveSurfaceForGhosttyAccess(reason: "sudo.trustedSurfaceScope") else {
            return nil
        }
        let rawTTYName = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(rawTTYName) }
        guard let pointer = rawTTYName.ptr else { return nil }
        let data = Data(bytes: pointer, count: Int(rawTTYName.len))
        let ttyName = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ttyName, !ttyName.isEmpty else { return nil }
        return ttyName
    }

    private nonisolated func v2SudoWorkingDirectory(for pid: pid_t) -> String? {
#if DEBUG
        if let override = CMUXSudoTestHooks.workingDirectoryOverride {
            return override(pid)
        }
#endif
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let copiedBytes = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )
        guard copiedBytes == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        let capacity = MemoryLayout.size(ofValue: info.pvi_cdir.vip_path)
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { rawPath in
                String(cString: rawPath)
            }
        }
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return path
    }

    private nonisolated func sanitizedHelperErrorCode(_ rawCode: String?) -> String {
        switch rawCode {
        case "helper_unavailable",
             "helper_transport_error",
             "helper_not_found",
             "helper_not_bundled",
             "helper_registration_failed",
             "helper_requires_approval",
             "helper_not_registered",
             "helper_unsupported",
             "helper_status_unknown",
             "cwd_unavailable",
             "missing_cwd",
             "command_timeout":
            return rawCode ?? "helper_error"
        default:
            return "helper_error"
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
            workingDirectory: request.cwd,
            result: result,
            exitCode: exitCode,
            errorCode: errorCode,
            message: message
        )
    }
}
