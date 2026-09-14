import Foundation

@MainActor
extension CloudTuiManualMirrorSession {
    /// Removes size and claim responses that belong to a hidden projection.
    func discardPendingSizingRequests() {
        pendingRequests = pendingRequests.filter { _, kind in
            switch kind {
            case .resize(_), .claim:
                return false
            case .identify, .clientInfo, .attach, .ping:
                return true
            }
        }
    }

    /// Returns whether a sizing claim is unavailable on an older daemon.
    static func isUnsupportedClaimError(_ error: String?) -> Bool {
        guard let error = error?.lowercased() else { return false }
        return error.contains("unknown command")
            || error.contains("unsupported")
            || error.contains("unrecognized command")
    }
}
