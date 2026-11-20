public import AppKit
import CmuxNextAgentPane
import CmuxAgentBrands
public import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextWakeups
import Foundation

/// The first-run Agents step over Settings > Agents > Harnesses' own reader: the rows it lists
/// (`_acpmux/harnesses`) with the `auth` their health check reports (`_acpmux/harness/health`),
/// and its Sign In gesture. No credential is read; acpmux reports only the state.
extension SettingsHarnesses: AgentSignInSource {
    /// The harnesses a person can sign in to: listed, not a terminal profile, with no launch
    /// problem, and found on this Mac by the health check (a path or a version; a check that
    /// answered with no row for it did not find it). A daemon that answered no health lists them
    /// all, their sign-in unknown. Named by the profile's display name, else the name cmux lists
    /// for the id ("Claude Code"), else the id. A harness the check did not find that cmux can
    /// install (Claude Code, Codex) is listed as not installed, for the step's Install; one with no
    /// row only when the daemon answered the list.
    var signInRows: [OnboardingAgent] {
        let listed: [OnboardingAgent] = rows.compactMap { row in
            guard row.kind != "terminal", row.problem == nil else { return nil }
            let health = health[row.id]
            // Missing only by a current answer: rows and health kept from before a failed read prove nothing now.
            let missing = listAnswered && healthAnswered && health?["path"]?.stringValue == nil && health?["version"]?.stringValue == nil
            if missing, OnboardingAgent.installPages[row.id] == nil { return nil }
            let known = AgentBrandCatalog.agents.first { $0.id == row.id.lowercased() }
            return OnboardingAgent(id: row.id, name: row.name ?? known?.name ?? row.id,
                                   brand: AgentBrandCatalog.brand(for: row.id)?.rawValue,
                                   auth: health?["auth"]?.stringValue.flatMap(OnboardingAgent.Auth.init(rawValue:)) ?? .unknown,
                                   installed: !missing)
        }
        // acpmux lists Claude Code or Codex only once it finds them: one its answer has no row for is not
        // here, and the step offers to install it. With no answer, nothing is known to be missing.
        guard listAnswered else { return listed }
        let absent = OnboardingAgent.installPages.keys.sorted().filter { id in !rows.contains { $0.id == id } }.map { id in
            OnboardingAgent(id: id, name: AgentBrandCatalog.agents.first { $0.id == id }?.name ?? id,
                            brand: AgentBrandCatalog.brand(for: id)?.rawValue, auth: .unknown, installed: false)
        }
        return listed + absent
    }

    /// Reads the harnesses and their health again (`recheck`: the daemon checks again instead of
    /// answering its last check), then answers ``signInRows``. Health only: no `claude auth status`.
    public func agentSignIns(recheck: Bool) async -> [OnboardingAgent] {
        await refresh(recheck: recheck, plans: false)
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

    /// Install: `acpmux harness install ID --json`, which runs the vendor's official installer
    /// (Claude Code's install.sh; the pinned, checksummed Codex release) and reloads the daemon.
    /// Nil when it installed, else acpmux's error, which names the vendor's install page.
    public func installAgent(_ id: String) async -> String? {
        guard OnboardingAgent.installPages[id] != nil else { return "cmux installs only Claude Code and Codex" }
        guard let environment = environment() else { return "cmux could not reach its agents service" }
        return await Self.install(id, environment)
    }

    @concurrent static func install(_ id: String, _ environment: AcpmuxEnvironment) async -> String? {
        var variables = ProcessInfo.processInfo.environment
        variables.merge(environment.childEnvironment) { $1 }
        // acpmux bounds the installer at 10 minutes; this limit only backs that up.
        let request = ProcessRequest(environment.executable, ["--json", "harness", "install", id],
                                     environment: variables, errorOutput: .separate, timeout: .seconds(15 * 60))
        guard let outcome = try? await AsyncProcess().run(request) else { return "the installer did not finish" }
        if outcome.succeeded { return nil }
        return failure(outcome.errorOutput, status: outcome.status)
    }

    /// acpmux's `--json` error (the last line of standard error): its message, else the text.
    nonisolated static func failure(_ stderr: Data, status: Int32) -> String {
        let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let last = text.split(separator: "\n").last.map(String.init) ?? ""
        let line = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
        if let message = (line?["error"] as? [String: Any])?["message"] as? String ?? line?["error"] as? String {
            return message
        }
        return text.isEmpty ? "the installer exited with \(status)" : last
    }

    public func agentIcon(_ agent: OnboardingAgent, side: CGFloat) -> NSImage? {
        agent.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: side) }
    }
}
