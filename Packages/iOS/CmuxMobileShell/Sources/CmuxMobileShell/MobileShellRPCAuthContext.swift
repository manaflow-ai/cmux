import CmuxMobileRPC
import Foundation

/// Immutable credential owner captured before an asynchronous mobile RPC flow begins.
struct MobileShellRPCAuthContext: Equatable, Sendable {
    let stackUserID: String?
    let accountScope: MobileRPCAuthScope
    let manualHostScope: MobileRPCAuthScope

    var hasStackUserID: Bool {
        stackUserID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
