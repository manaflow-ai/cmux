import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextRemote
import Foundation

/// Peer-route approvals in the app (acpmux `hub/mac_approvers.rs`): where this Mac's approver key
/// lives, and what the pane's Enroll this Mac runs.
enum PeerApprovalsApp {
    /// The app's one approver (made once at launch, before any pane connects). A signed
    /// build keeps the key in the Secure Enclave (its blob in this app's data-protection Keychain); a
    /// DEV build without a Team ID keeps a memory key for this launch. Enroll runs the app's own
    /// cmux-tui, `acp host approvals enroll PEER`, which enrolls the key on that machine over the person's ssh.
    @MainActor static func approver() -> AgentPanePeerApprover {
        let service = (Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next") + ".mac-approver"
        let key = AcpmuxMacApprover(keychainService: CodeSigningTeam.current() == nil ? nil : service)
        guard let binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment) else { return .init(key: key) }
        return AgentPanePeerApprover(key: key) { peer, daemon in
            // The person's ssh environment, and the daemon the pane talks to (a DEV or tagged
            // build's own acpmux home), which knows the peer and holds this Mac's key.
            let cli = HostCLI(binary: binary) { await SSHService.environment().merging(daemon) { _, own in own } }
            return await enrolled(peer, cli: cli)
        }
    }

    /// nil once `peer` enrolled this Mac; else the command's own words for what failed.
    static func enrolled(_ peer: String, cli: HostCLI) async -> String? {
        var last: [String: Any]?
        do {
            for try await line in cli.lines(["acp", "host", "approvals", "enroll", peer, "--json"]) {
                if let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { last = object }
            }
        } catch {
            return failure(last) ?? error.localizedDescription
        }
        guard let state = last?["state"] as? String, state == "ok" || state == "fixed" else { return failure(last) ?? "" }
        return nil
    }

    /// A step line's detail, then its fix (`acpmux host update NAME`, open cmux, ...).
    private static func failure(_ step: [String: Any]?) -> String? {
        guard let detail = step?["detail"] as? String, !detail.isEmpty else { return nil }
        guard let fix = step?["fix"] as? String, !fix.isEmpty else { return detail }
        return detail + " (" + fix + ")"
    }
}
