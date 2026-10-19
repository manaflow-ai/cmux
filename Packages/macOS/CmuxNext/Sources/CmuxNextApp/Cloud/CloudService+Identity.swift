import CmuxNextCloud
import CmuxNextCompat
import Foundation
import os

/// The Mac name and original install registration used by Cloud transports.
extension CloudService {
    /// `cmux-<host>`, as the old app named its link device. Reads the kernel
    /// hostname (`gethostname`): `ProcessInfo.hostName` resolves through DNS
    /// and blocked the main thread for 35 s on launch.
    static var deviceName: String {
        let name = MacName.kernelHostName()
        let host = name.isEmpty ? "mac" : name
        let cleaned = host.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "cmux-" + String(String(cleaned).prefix(40))
    }

    func localDeviceID() throws -> String { try paths.loadOrCreateDeviceID() }

    /// Registers (or reuses) this Mac's install for the signed-in user and
    /// mints one token. A failure is logged: the relay mints again when it
    /// needs a token, and the hub path does not depend on it.
    func installSignedIn() async {
        guard let stackUser = auth.user?.id, mayCallCloud else { return }
        let auth = auth
        do {
            try await installIdentity.signedIn(stackUser: stackUser, session: { try await auth.tokens().access })
        } catch {
            logger.error("install registration failed: \(String(describing: error), privacy: .public)")
        }
    }
    /// Whether a Cloud API request may go out: not turned off by the
    /// organization, the managed team present (P17-3), not a local-only
    /// backend. (A missing cmux-tui client blocks machines, not the API.)
    var mayCallCloud: Bool {
        cloudTeam.canCall
    }

    /// Set while an administrator turned Cloud off (`DisabledFeatures`).
    var policyDisabled: Bool { cloudTeam.policyDisabled }


}
