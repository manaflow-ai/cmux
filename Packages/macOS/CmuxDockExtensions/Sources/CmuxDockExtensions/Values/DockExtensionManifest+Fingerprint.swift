import CryptoKit
import Foundation

extension DockExtensionManifest {
    /// Deterministic fingerprint over everything the user consented to run:
    /// the pinned commit plus every build/pane command, working directory, and
    /// env entry. When a checkout's manifest no longer matches the recorded
    /// fingerprint (or an update changes any command), cmux re-asks for
    /// consent — the same idea as the Dock config's `CmuxActionTrust`
    /// fingerprint.
    ///
    /// - Parameter pinnedSha: The pinned commit SHA, or `nil` for linked
    ///   development extensions (which are consented by the act of linking).
    /// - Returns: A stable hex SHA-256 digest.
    public func consentFingerprint(pinnedSha: String?) -> String {
        var lines: [String] = []
        lines.append("v1")
        lines.append("sha:\(pinnedSha ?? "linked")")
        lines.append("id:\(id)")
        for step in build {
            lines.append("build:\(Self.fingerprintField(step.command))")
        }
        for pane in panes {
            lines.append("pane:\(pane.id)")
            lines.append("pane.command:\(Self.fingerprintField(pane.command))")
            lines.append("pane.cwd:\(pane.cwd ?? "")")
            for key in pane.env.keys.sorted() {
                lines.append("pane.env:\(key)=\(pane.env[key] ?? "")")
            }
        }
        let canonical = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Joins an argv with a separator no argument can contain unescaped, so
    /// `["a b"]` and `["a", "b"]` fingerprint differently.
    private static func fingerprintField(_ argv: [String]) -> String {
        argv.joined(separator: "\u{1F}")
    }
}
