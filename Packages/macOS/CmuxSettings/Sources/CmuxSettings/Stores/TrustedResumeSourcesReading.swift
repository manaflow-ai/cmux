import Foundation

/// Read access to the trusted resume-source allowlist
/// (`terminal.trustedResumeSources`).
///
/// Resume-command approvals are normally keyed to a binding's exact command,
/// which includes an agent's per-session identifier (for example
/// `rovo run --restore <session-id>`). Agents that mint a new session id per
/// tab therefore produce a never-before-approved command on every new session,
/// so the approval prompt reappears each time. Listing an agent's source here
/// trusts all of its future resume commands.
///
/// Consumers (resume-approval and auto-resume glue in the app target) depend on
/// this seam instead of the concrete ``TrustedResumeSourcesStore`` so they can
/// be tested with a fixed fake and never name the storage mechanism.
public protocol TrustedResumeSourcesReading: Sendable {
    /// The normalized, lowercased allowlist of trusted resume-command sources.
    ///
    /// Empty by default, which preserves the standard prompt behavior.
    var trustedSources: [String] { get }
}

extension TrustedResumeSourcesReading {
    /// Whether a resume binding described by `source` and/or `name` is trusted.
    ///
    /// Matching is case-insensitive and checks `source` first, then `name`, so
    /// callers can trust a binding by either its machine source token or its
    /// human-facing agent name.
    ///
    /// - Parameters:
    ///   - source: The binding's machine source token (for example `rovo`).
    ///   - name: The binding's human-facing agent name, if any.
    /// - Returns: `true` when either candidate appears in ``trustedSources``.
    public func isTrusted(source: String?, name: String? = nil) -> Bool {
        let allowlist = trustedSources
        guard !allowlist.isEmpty else { return false }
        let candidates = [source, name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return false }
        let allowed = Set(allowlist)
        return candidates.contains { allowed.contains($0) }
    }
}

extension TrustedResumeSourcesReading {
    /// Normalizes a raw allowlist by trimming whitespace, lowercasing, and
    /// dropping empty entries. Shared by the store and its fakes so every
    /// reader applies identical matching semantics.
    ///
    /// - Parameter rawSources: The unnormalized source entries.
    /// - Returns: Trimmed, lowercased, non-empty source tokens.
    public static func normalize(_ rawSources: [String]) -> [String] {
        rawSources
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
