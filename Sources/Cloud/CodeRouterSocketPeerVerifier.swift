import CmuxControlSocket
import Darwin
import Foundation
import Security

@_silgen_name("csops_audittoken")
private func cmuxCodeSigningOperationsForAuditToken(
    _ processID: pid_t,
    _ operation: UInt32,
    _ destination: UnsafeMutableRawPointer?,
    _ destinationSize: Int,
    _ auditToken: UnsafeMutableRawPointer?
) -> Int32

/// Injectable audit-token verifier for the one signed CodeRouter socket path.
struct CodeRouterSocketPeerVerifier: Sendable {
    static let production = Self { token in
        productionValidation(token)
    }

    private static let signingRequirement =
        #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier "com.cmuxterm.coderouter" and certificate leaf[subject.OU] = "7WLXT3NR37""#
    private static let validFlag: UInt32 = 0x0000_0001
    private static let hardFlag: UInt32 = 0x0000_0100
    private static let killFlag: UInt32 = 0x0000_0200
    private static let hardenedRuntimeFlag: UInt32 = 0x0001_0000
    private static let debuggedFlag: UInt32 = 0x1000_0000

    private let validation: @Sendable (SocketPeerAuditToken) -> Bool

    init(validation: @escaping @Sendable (SocketPeerAuditToken) -> Bool) {
        self.validation = validation
    }

    func isTrusted(_ token: SocketPeerAuditToken) -> Bool {
        validation(token)
    }

    /// Resolves dynamic code by the exact audit token. Repeating this call
    /// rejects a PID reuse or `exec` because its old audit token no longer
    /// names the running guest.
    private static func productionValidation(
        _ token: SocketPeerAuditToken
    ) -> Bool {
        let attributes = [
            kSecGuestAttributeAudit: Data(token.bytes) as CFData,
        ] as CFDictionary
        var dynamicCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &dynamicCode
        ) == errSecSuccess,
              let dynamicCode else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            signingRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(
                  dynamicCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess else {
            return false
        }

        var dynamicStatus: UInt32 = 0
        var auditToken = audit_token_t()
        token.bytes.withUnsafeBytes { bytes in
            withUnsafeMutableBytes(of: &auditToken) { destination in
                destination.copyBytes(from: bytes)
            }
        }
        let dynamicStatusResult = withUnsafeMutablePointer(
            to: &dynamicStatus
        ) { pointer in
            withUnsafeMutablePointer(to: &auditToken) { auditPointer in
                cmuxCodeSigningOperationsForAuditToken(
                token.processID,
                0, // CS_OPS_STATUS
                pointer,
                MemoryLayout<UInt32>.size,
                auditPointer
                )
            }
        }
        let requiredDynamicFlags = validFlag | hardFlag | killFlag
            | hardenedRuntimeFlag
        let cmuxRealUserID = getuid()
        let cmuxEffectiveUserID = geteuid()
        guard cmuxRealUserID == cmuxEffectiveUserID,
              token.effectiveUserID == cmuxEffectiveUserID,
              token.realUserID == cmuxRealUserID,
              dynamicStatusResult == 0,
              dynamicStatus & requiredDynamicFlags == requiredDynamicFlags,
              dynamicStatus & debuggedFlag == 0 else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            dynamicCode,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            return false
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(
                rawValue: kSecCSSigningInformation
                    | kSecCSRequirementInformation
            ),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as NSDictionary?,
              let flags = information[kSecCodeInfoFlags] as? NSNumber,
              flags.uint32Value & hardenedRuntimeFlag != 0 else {
            return false
        }

        // CodeRouter needs no entitlements. An empty allowlist avoids a later
        // entitlement addition silently widening this credential path.
        if let rawEntitlements = information[kSecCodeInfoEntitlementsDict] {
            guard let entitlements = rawEntitlements as? NSDictionary,
                  entitlements.count == 0 else {
                return false
            }
        }
        return true
    }
}
