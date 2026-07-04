import CryptoKit
import Foundation

/// Deterministic fingerprint over everything the user consented to run: the
/// pinned commit plus every build/pane command, working directory, and env
/// entry. When a checkout's manifest no longer matches the recorded
/// fingerprint (or an update changes any command), cmux re-asks for consent —
/// the same idea as the Dock config's `CmuxActionTrust` fingerprint.
public enum DockExtensionFingerprint {
    /// Computes the consent fingerprint for a manifest at a pinned revision.
    ///
    /// - Parameters:
    ///   - pinnedSha: The pinned commit SHA, or `nil` for linked development
    ///     extensions (which are consented by the act of linking).
    ///   - manifest: The parsed manifest as consented.
    /// - Returns: A stable hex SHA-256 digest.
    public static func compute(pinnedSha: String?, manifest: DockExtensionManifest) -> String {
        var lines: [String] = []
        lines.append("v1")
        lines.append("sha:\(pinnedSha ?? "linked")")
        lines.append("id:\(manifest.id)")
        for step in manifest.build {
            lines.append("build:\(joined(step.command))")
        }
        for pane in manifest.panes {
            lines.append("pane:\(pane.id)")
            lines.append("pane.command:\(joined(pane.command))")
            lines.append("pane.cwd:\(pane.cwd ?? "")")
            for key in pane.env.keys.sorted() {
                lines.append("pane.env:\(key)=\(pane.env[key] ?? "")")
            }
        }
        let canonical = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func joined(_ argv: [String]) -> String {
        argv.joined(separator: "\u{1F}")
    }
}
