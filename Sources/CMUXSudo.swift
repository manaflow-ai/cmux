import Darwin
import Foundation

struct CMUXSudoCommandRequest: Sendable {
    let requestID: String
    let argv: [String]
    let displayCommand: String
    let workspaceID: UUID
    let surfaceID: UUID
    let callerPID: pid_t
    let callerUID: uid_t
    let cwd: String?

    func withWorkingDirectory(_ cwd: String) -> CMUXSudoCommandRequest {
        CMUXSudoCommandRequest(
            requestID: requestID,
            argv: argv,
            displayCommand: displayCommand,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            callerPID: callerPID,
            callerUID: callerUID,
            cwd: cwd
        )
    }

    static func parse(params: [String: Any]) -> Result<CMUXSudoCommandRequest, CMUXSudoRequestError> {
        let requestID = (params["request_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRequestID = requestID?.isEmpty == false ? requestID! : UUID().uuidString

        guard let rawArgv = params["argv"] as? [Any], !rawArgv.isEmpty else {
            return .failure(.invalidParams(String(localized: "sudo.error.argvArray", defaultValue: "argv must be a non-empty string array")))
        }
        var argv: [String] = []
        argv.reserveCapacity(rawArgv.count)
        for value in rawArgv {
            guard let arg = value as? String, !arg.contains("\0") else {
                return .failure(.invalidParams(String(localized: "sudo.error.argvStringsNoNUL", defaultValue: "argv must contain only strings without NUL bytes")))
            }
            argv.append(arg)
        }
        guard argv.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .failure(.invalidParams(String(localized: "sudo.error.argvExecutable", defaultValue: "argv[0] must be a command path or executable name")))
        }

        guard let workspaceRaw = params["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: workspaceRaw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.invalidParams(String(localized: "sudo.error.workspaceUUID", defaultValue: "workspace_id must be a UUID")))
        }
        guard let surfaceRaw = params["surface_id"] as? String,
              let surfaceID = UUID(uuidString: surfaceRaw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.invalidParams(String(localized: "sudo.error.surfaceUUID", defaultValue: "surface_id must be a UUID")))
        }
        guard let callerPID = pidValue(params["caller_pid"]), callerPID > 0 else {
            return .failure(.invalidParams(String(localized: "sudo.error.callerPID", defaultValue: "caller_pid must be a positive integer")))
        }
        guard let callerUID = uidValue(params["caller_uid"]) else {
            return .failure(.invalidParams(String(localized: "sudo.error.callerUID", defaultValue: "caller_uid must be an integer")))
        }

        return .success(
            CMUXSudoCommandRequest(
                requestID: effectiveRequestID,
                argv: argv,
                displayCommand: CMUXSudoCommandLine.display(argv),
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                callerPID: callerPID,
                callerUID: callerUID,
                cwd: nil
            )
        )
    }

    private static func pidValue(_ value: Any?) -> pid_t? {
        func checked(_ value: Int64) -> pid_t? {
            guard value > 0, value <= Int64(Int32.max) else { return nil }
            return pid_t(value)
        }
        if let value = value as? Int { return checked(Int64(value)) }
        if let value = strictInt64Value(value) { return checked(value) }
        if let value = value as? String,
           let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return checked(parsed)
        }
        return nil
    }

    private static func uidValue(_ value: Any?) -> uid_t? {
        func checked(_ value: UInt64) -> uid_t? {
            guard value <= UInt64(UInt32.max) else { return nil }
            return uid_t(value)
        }
        if let value = value as? UInt { return checked(UInt64(value)) }
        if let value = value as? Int, value >= 0 { return checked(UInt64(value)) }
        if let signed = strictInt64Value(value) {
            guard signed >= 0 else { return nil }
            return checked(UInt64(signed))
        }
        if let value = value as? String,
           let parsed = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return checked(parsed)
        }
        return nil
    }

    private static func strictInt64Value(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= Double(Int64.min),
              doubleValue <= Double(Int64.max) else {
            return nil
        }
        return number.int64Value
    }
}

enum CMUXSudoRequestError: Error, Sendable {
    case invalidParams(String)
    case accessDenied(String)
    case authenticationDenied(String)
    case auditUnavailable(String)
    case helperUnavailable(String)

    var code: String {
        switch self {
        case .invalidParams: return "invalid_params"
        case .accessDenied: return "access_denied"
        case .authenticationDenied: return "authentication_denied"
        case .auditUnavailable: return "audit_unavailable"
        case .helperUnavailable: return "helper_unavailable"
        }
    }

    var message: String {
        switch self {
        case .invalidParams(let message),
             .accessDenied(let message),
             .authenticationDenied(let message),
             .auditUnavailable(let message),
             .helperUnavailable(let message):
            return message
        }
    }
}

enum CMUXSudoCommandLine {
    static func display(_ argv: [String]) -> String {
        argv.map(shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-./:=,@%")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct CMUXSudoCallerValidationResult: Sendable {
    let allowed: Bool
    let reason: String?
}

struct CMUXSudoTrustedSurfaceScope: Hashable, Sendable {
    let workspaceID: UUID
    let surfaceID: UUID
}

enum CMUXSudoCallerValidator {
    static func validate(
        request: CMUXSudoCommandRequest,
        peerIdentity: CMUXSocketPeerIdentity,
        isDescendant: (pid_t) -> Bool,
        trustedSurfaceScope: (pid_t) -> CMUXSudoTrustedSurfaceScope?
    ) -> CMUXSudoCallerValidationResult {
        guard let peerPID = peerIdentity.pid, peerPID > 0 else {
            return .init(allowed: false, reason: String(localized: "sudo.error.peerPIDUnavailable", defaultValue: "socket peer pid is unavailable"))
        }
        guard let peerUID = peerIdentity.uid else {
            return .init(allowed: false, reason: String(localized: "sudo.error.peerUIDUnavailable", defaultValue: "socket peer uid is unavailable"))
        }
        guard peerIdentity.processStartTime != nil else {
            return .init(allowed: false, reason: String(localized: "sudo.error.peerProcessUnavailable", defaultValue: "socket peer process identity is unavailable"))
        }
        guard peerPID == request.callerPID else {
            return .init(allowed: false, reason: String(localized: "sudo.error.pidMismatch", defaultValue: "caller_pid does not match socket peer pid"))
        }
        guard peerUID == request.callerUID, peerUID == getuid() else {
            return .init(allowed: false, reason: String(localized: "sudo.error.uidMismatch", defaultValue: "caller_uid does not match socket peer uid"))
        }
        guard isDescendant(peerPID) else {
            return .init(allowed: false, reason: String(localized: "sudo.error.notCmuxChild", defaultValue: "requesting process is not a cmux child"))
        }
        guard let scope = trustedSurfaceScope(peerPID) else {
            return .init(allowed: false, reason: String(localized: "sudo.error.noTrustedScope", defaultValue: "requesting process has no trusted cmux terminal scope"))
        }
        guard scope.workspaceID == request.workspaceID, scope.surfaceID == request.surfaceID else {
            return .init(allowed: false, reason: String(localized: "sudo.error.trustedScopeMismatch", defaultValue: "request scope does not match requesting terminal surface"))
        }
        return .init(allowed: true, reason: nil)
    }
}
