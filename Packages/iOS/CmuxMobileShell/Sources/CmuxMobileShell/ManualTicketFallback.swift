import CmuxMobileRPC
import Foundation

/// Whether an RPC error means the host needs the legacy manual-ticket fallback.
func shouldFallbackToSyntheticManualTicket(after error: any Error) -> Bool {
    guard case let MobileShellConnectionError.rpcError(code, message) = error else {
        return false
    }
    let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let normalizedCode,
       ["method_not_found", "not_found", "unknown_method", "unsupported_method"].contains(normalizedCode) {
        return true
    }
    return normalizedMessage.contains("unknown method")
        || normalizedMessage.contains("method not found")
        || normalizedMessage.contains("unsupported method")
        || normalizedMessage.contains("ticket unavailable")
        || normalizedMessage.contains("ticket not available")
}
