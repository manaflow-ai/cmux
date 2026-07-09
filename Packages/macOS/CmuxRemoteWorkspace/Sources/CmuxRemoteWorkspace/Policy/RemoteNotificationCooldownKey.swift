import Foundation

/// Derives the per-host throttle key used to rate-limit remote-connection
/// notifications (so repeated SSH/proxy errors for one host do not spam the
/// user).
///
/// Pure value/decision helper extracted from the legacy
/// `Workspace.remoteNotificationCooldownKey(target:)`. The workspace supplies
/// its configured remote destination (preferred when present) and the call's
/// `target`; this type trims, strips any `user@` prefix, lowercases the host,
/// and returns a `remote-host:<host>` key, or `nil` when no usable host can be
/// derived. Byte-faithful to the legacy normalization.
public struct RemoteNotificationCooldownKey: Sendable {
    /// Creates the key deriver.
    public init() {}

    /// The cooldown key for `destination`/`target`, or `nil` when neither
    /// yields a non-empty host after normalization.
    public func key(destination: String?, target: String) -> String? {
        let rawTarget = (destination ?? target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTarget.isEmpty else { return nil }
        let normalizedHost = rawTarget
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedHost, !normalizedHost.isEmpty else { return nil }
        return "remote-host:\(normalizedHost)"
    }
}
