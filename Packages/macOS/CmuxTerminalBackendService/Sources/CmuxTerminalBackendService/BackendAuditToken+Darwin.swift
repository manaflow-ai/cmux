internal import CmuxTerminalBackend
internal import Darwin
internal import Foundation

extension BackendAuditToken {
    /// Reconstructs the Darwin token without interpreting its opaque words.
    internal var systemValue: audit_token_t {
        audit_token_t(
            val: (
                word0,
                word1,
                word2,
                word3,
                word4,
                word5,
                word6,
                word7
            )
        )
    }

    /// Security.framework expects `kSecGuestAttributeAudit` as raw token data.
    internal var securityAttributeData: Data {
        var token = systemValue
        return withUnsafeBytes(of: &token) { Data($0) }
    }
}
