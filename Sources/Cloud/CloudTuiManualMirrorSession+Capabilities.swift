import Foundation

extension CloudTuiManualMirrorSession {
    /// Never downgrade to an unleased attachment when the peer promises fencing.
    nonisolated static func requiresLeaseToken(capabilities: [String], lease: String?) -> Bool {
        capabilities.contains("view-attachment-lease-v1") && lease?.isEmpty != false
    }

    static func isUnsupportedClaimError(_ error: String?) -> Bool {
        guard let error = error?.lowercased() else { return false }
        return error.contains("unknown command")
            || error.contains("unsupported")
            || error.contains("unrecognized command")
    }
}
