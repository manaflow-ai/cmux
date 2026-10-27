import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Peer-route approvals in the app (acpmux `hub/mac_approvers.rs`): where this Mac's approver key
/// lives.
enum PeerApprovalsApp {
    /// A signed build keeps the key in the Secure Enclave (its blob in this app's data-protection
    /// Keychain); a DEV build without a Team ID keeps a memory key for this launch.
    @MainActor static func install() {
        let service = (Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next") + ".mac-approver"
        AcpmuxMacApprover.shared.configure(keychainService: CodeSigningTeam.current() == nil ? nil : service)
    }
}
