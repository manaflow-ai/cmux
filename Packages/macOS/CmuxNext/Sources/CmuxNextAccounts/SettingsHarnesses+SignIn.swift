public import AppKit
import CmuxAgentBrands
public import CmuxNextOnboarding
import CmuxNextPages

/// The first-run Agents step over Settings > Agents > Harnesses' own reader: the rows it lists
/// (`_acpmux/harnesses`) with the `auth` their health check reports (`_acpmux/harness/health`),
/// and its Sign In gesture. No credential is read; acpmux reports only the state.
extension SettingsHarnesses: AgentSignInSource {
    /// The harnesses a person can sign in to: listed, not a terminal profile, with no launch
    /// problem, and found on this Mac by the health check (a path or a version; a check that
    /// answered with no row for it did not find it). A daemon that answered no health lists them
    /// all, their sign-in unknown. Named by the profile's display name, else the name cmux lists
    /// for the id ("Claude Code"), else the id.
    var signInRows: [OnboardingAgent] {
        rows.compactMap { row in
            guard row.kind != "terminal", row.problem == nil else { return nil }
            let health = health[row.id]
            if healthAnswered, health?["path"]?.stringValue == nil, health?["version"]?.stringValue == nil { return nil }
            let known = AgentBrandCatalog.agents.first { $0.id == row.id.lowercased() }
            return OnboardingAgent(id: row.id, name: row.name ?? known?.name ?? row.id,
                                   brand: AgentBrandCatalog.brand(for: row.id)?.rawValue,
                                   auth: health?["auth"]?.stringValue.flatMap(OnboardingAgent.Auth.init(rawValue:)) ?? .unknown)
        }
    }

    /// Reads the harnesses and their health again (`recheck`: the daemon checks again instead of
    /// answering its last check), then answers ``signInRows``.
    public func agentSignIns(recheck: Bool) async -> [OnboardingAgent] {
        await refresh(recheck: recheck)
        return signInRows
    }

    /// Sign In: the Settings page's own `signIn` gesture, which types
    /// `acpmux harness login -- <id>` into a new terminal tab. False when it refused.
    public func signInAgent(_ id: String) async -> Bool {
        do {
            _ = try await run(["action": .string("signIn"), "id": .string(id)], context: nil)
            return true
        } catch {
            return false
        }
    }

    public func agentIcon(_ agent: OnboardingAgent, side: CGFloat) -> NSImage? {
        agent.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: side) }
    }
}
