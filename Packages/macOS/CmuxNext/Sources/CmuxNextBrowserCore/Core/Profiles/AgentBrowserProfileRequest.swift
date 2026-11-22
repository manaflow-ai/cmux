import Foundation

/// openBrowser's optional `profile` argument (plans/cmux-next/passwords.md,
/// section 3.4): no argument takes the cascade, "agent" the clean agent
/// profile (one fixed id cmux creates on first use, no extensions, no cookies
/// shared with the person's profiles), any other value must be a profile id.
public nonisolated enum AgentBrowserProfileRequest: Equatable, Sendable {
    /// No argument: the workspace's, the space's, or `default`.
    case cascade
    case explicit(String)
    case agent

    /// nil: not "agent" and not a profile id.
    public init?(raw: String?) {
        guard let raw, !raw.isEmpty else { self = .cascade; return }
        if raw.lowercased() == "agent" { self = .agent; return }
        guard BrowserProfileRecord.isValidID(raw) else { return nil }
        self = .explicit(raw)
    }

    /// The agent profile was created but its record never came back from the home daemon.
    public struct NotReported: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "the browser profile was created but not reported back by the home daemon" }
    }
}
