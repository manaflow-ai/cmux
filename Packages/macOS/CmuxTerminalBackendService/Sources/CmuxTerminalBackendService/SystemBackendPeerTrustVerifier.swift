public import CmuxTerminalBackend
internal import Darwin
public import Foundation
internal import Security

/// Authenticates the kernel-identified daemon against cmux's code signature.
public struct SystemBackendPeerTrustVerifier: BackendPeerTrustVerifying, Sendable {
    /// The dedicated signing identifier applied to every terminal backend build.
    public static let signingIdentifier = "com.cmuxterm.cmux-terminal-backend"

    private let expectedExecutableURL: URL
    private let expectedSigningIdentifier: String

    /// Creates a verifier for the helper embedded in one cmux app bundle.
    ///
    /// - Parameters:
    ///   - expectedExecutableURL: The bundled backend executable path.
    ///   - expectedSigningIdentifier: The dedicated helper signing identifier.
    public init(
        expectedExecutableURL: URL,
        expectedSigningIdentifier: String = SystemBackendPeerTrustVerifier.signingIdentifier
    ) {
        self.expectedExecutableURL = expectedExecutableURL
        self.expectedSigningIdentifier = expectedSigningIdentifier
    }

    /// Validates the peer's live code signature, identifier, team, and debug path.
    ///
    /// The helper must execute from the exact current bundle path. Production
    /// signatures must also share the app's Developer ID team. Ad-hoc
    /// development signatures must have no team identifier.
    public func verify(_ identity: BackendPeerIdentity) throws -> BackendPeerTrustEvidence {
        var auditToken = identity.auditToken.systemValue
        let auditProcessID = audit_token_to_pid(auditToken)
        guard auditProcessID > 0, UInt32(auditProcessID) == identity.processID else {
            throw BackendPeerTrustError.auditTokenProcessMismatch(
                socket: identity.processID,
                auditToken: auditProcessID
            )
        }
        let auditUserID = audit_token_to_euid(auditToken)
        guard auditUserID == identity.userID else {
            throw BackendPeerTrustError.auditTokenUserMismatch(
                socket: identity.userID,
                auditToken: auditUserID
            )
        }
        let processIDVersion = audit_token_to_pidversion(auditToken)

        let dynamicCode = try dynamicCode(auditToken: identity.auditToken)
        let validityStatus = SecCodeCheckValidity(
            dynamicCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validityStatus == errSecSuccess else {
            throw BackendPeerTrustError.security(
                operation: "SecCodeCheckValidity(peer audit token)",
                status: validityStatus
            )
        }

        let peerCode = try staticCode(dynamicCode: dynamicCode)
        let peerInformation = try signingInformation(for: peerCode, operation: "peer signing info")
        let peerIdentifier = peerInformation[kSecCodeInfoIdentifier] as? String
        guard peerIdentifier == expectedSigningIdentifier else {
            throw BackendPeerTrustError.unexpectedSigningIdentifier(
                expected: expectedSigningIdentifier,
                actual: peerIdentifier
            )
        }
        let peerTeam = normalizedTeamIdentifier(
            peerInformation[kSecCodeInfoTeamIdentifier] as? String
        )
        let executableURL = try processExecutableURL(
            auditToken: &auditToken,
            processID: identity.processID,
            processIDVersion: processIDVersion
        )
        let appTeam = try currentProcessTeamIdentifier()
        let expectedPath = canonicalPath(expectedExecutableURL)
        let actualPath = canonicalPath(executableURL)
        guard actualPath == expectedPath else {
            throw BackendPeerTrustError.unexpectedExecutable(
                expected: expectedPath,
                actual: actualPath
            )
        }

        if let appTeam {
            guard peerTeam == appTeam else {
                throw BackendPeerTrustError.unexpectedTeamIdentifier(
                    expected: appTeam,
                    actual: peerTeam
                )
            }
        } else {
            guard peerTeam == nil else {
                throw BackendPeerTrustError.unexpectedTeamIdentifier(
                    expected: "ad-hoc",
                    actual: peerTeam
                )
            }
        }

        return BackendPeerTrustEvidence(
            signingIdentifier: peerIdentifier ?? expectedSigningIdentifier,
            teamIdentifier: peerTeam,
            executableURL: executableURL,
            processIDVersion: processIDVersion
        )
    }

    private func dynamicCode(auditToken: BackendAuditToken) throws -> SecCode {
        let attributes = [
            kSecGuestAttributeAudit: auditToken.securityAttributeData
        ] as CFDictionary
        var dynamicCode: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamicCode)
        guard guestStatus == errSecSuccess, let dynamicCode else {
            throw BackendPeerTrustError.security(
                operation: "SecCodeCopyGuestWithAttributes",
                status: guestStatus
            )
        }
        return dynamicCode
    }

    private func staticCode(dynamicCode: SecCode) throws -> SecStaticCode {
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw BackendPeerTrustError.security(
                operation: "SecCodeCopyStaticCode",
                status: staticStatus
            )
        }
        return staticCode
    }

    private func signingInformation(
        for code: SecStaticCode,
        operation: String
    ) throws -> NSDictionary {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard status == errSecSuccess, let information else {
            throw BackendPeerTrustError.security(operation: operation, status: status)
        }
        return information as NSDictionary
    }

    private func currentProcessTeamIdentifier() throws -> String? {
        var dynamicCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &dynamicCode)
        guard selfStatus == errSecSuccess, let dynamicCode else {
            throw BackendPeerTrustError.security(
                operation: "SecCodeCopySelf",
                status: selfStatus
            )
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw BackendPeerTrustError.security(
                operation: "SecCodeCopyStaticCode(self)",
                status: staticStatus
            )
        }
        let information = try signingInformation(for: staticCode, operation: "app signing info")
        return normalizedTeamIdentifier(information[kSecCodeInfoTeamIdentifier] as? String)
    }

    private func processExecutableURL(
        auditToken: inout audit_token_t,
        processID: UInt32,
        processIDVersion: Int32
    ) throws -> URL {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath_audittoken(&auditToken, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            throw BackendPeerTrustError.executableUnavailable(
                processID: processID,
                processIDVersion: processIDVersion
            )
        }
        let path = String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private func normalizedTeamIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
