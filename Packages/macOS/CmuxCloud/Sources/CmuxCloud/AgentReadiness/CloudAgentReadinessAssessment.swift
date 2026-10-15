import Foundation

/// What a readiness entry means for the person: one status, the credential and
/// endpoint in words, why, and at most one fix. Shared by `cmux vm doctor`, the
/// pre-launch warning of `vm agent` / `vm clone --agent`, and the app's Agents
/// section, so all three say the same thing.
public struct CloudAgentReadinessAssessment: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        /// The launch has a credential and sends it where it belongs.
        case ready
        /// It may work, but something is off (a key's endpoint not applied yet,
        /// the provider unreachable or rate limiting, git not wired to the token).
        case attention
        /// The launch will fail or send a key where it does not belong.
        case problem
        /// The machine could not say (an account check that got no answer).
        case unknown
    }

    public let entry: CloudAgentReadinessEntry
    public let status: Status
    /// The credential the launch uses, e.g. "Cloud Secrets: ANTHROPIC_API_KEY".
    public let credential: String
    /// Where it goes, e.g. "api.anthropic.com" or "cmux model routing".
    public let endpoint: String
    /// One sentence on the status, e.g. "Key rejected by Anthropic (401)."
    public let detail: String
    /// One line that fixes it, usually a command, e.g. "Add ANTHROPIC_API_KEY: cmux vm secrets set ANTHROPIC_API_KEY".
    public let fix: String?

    /// - Parameters:
    ///   - machine: how commands in `fix` address the machine (a label or an id).
    ///   - vaultNames: names Cloud Secrets delivered to this machine, so a key
    ///     from the vault reads "Cloud Secrets" and one set otherwise "Machine env".
    public init(entry: CloudAgentReadinessEntry, machine: String, vaultNames: Set<String> = []) {
        self.entry = entry
        let provider = entry.keyName.map(Self.providerName(forKey:)) ?? Self.defaultProvider(for: entry.agent)
        credential = Self.credentialLabel(entry, vaultNames: vaultNames)
        endpoint = Self.endpointLabel(entry)
        let outcome = Self.outcome(entry, provider: provider, machine: machine)
        status = outcome.status
        detail = outcome.detail
        fix = outcome.fix
    }

    /// True when `vm agent` should print a warning line before launching: the
    /// agent has no usable credential, or would send a key where it does not belong.
    public var warnsBeforeLaunch: Bool { status == .problem }

    /// A short status word for a table cell or a chip.
    public var statusLabel: String {
        switch status {
        case .ready:
            if case .status(let code) = entry.probe, (200..<300).contains(code) {
                return String(localized: "cloudAgentReadiness.status.keyAccepted", defaultValue: "Key works")
            }
            return String(localized: "cloudAgentReadiness.status.ready", defaultValue: "Ready")
        case .attention:
            return String(localized: "cloudAgentReadiness.status.attention", defaultValue: "Check")
        case .problem:
            if !entry.installed {
                return String(localized: "cloudAgentReadiness.status.notInstalled", defaultValue: "Not installed")
            }
            return String(localized: "cloudAgentReadiness.status.problem", defaultValue: "Needs a fix")
        case .unknown:
            return String(localized: "cloudAgentReadiness.status.unknown", defaultValue: "Unknown")
        }
    }

    /// The agent's name as people know it.
    public static func displayName(_ agent: CloudAgentReadinessAgent) -> String {
        switch agent {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        case .gh: return String(localized: "cloudAgentReadiness.agent.gh", defaultValue: "GitHub (gh, git)")
        }
    }

    /// The key a person adds so `agent` can start without a sign-in.
    public static func suggestedKey(for agent: CloudAgentReadinessAgent) -> String {
        switch agent {
        case .claude, .pi: return "ANTHROPIC_API_KEY"
        case .codex: return "OPENAI_API_KEY"
        case .opencode: return "OPENROUTER_API_KEY"
        case .gh: return "GH_TOKEN"
        }
    }

    // MARK: - Words

    static func providerName(forKey key: String) -> String {
        let prefixes: [(String, String)] = [
            ("ANTHROPIC_", "Anthropic"), ("OPENAI_", "OpenAI"), ("OPENROUTER_", "OpenRouter"),
            ("GEMINI_", "Google"), ("GOOGLE_", "Google"), ("GH_", "GitHub"), ("GITHUB_", "GitHub"),
            ("XAI_", "xAI"), ("GROQ_", "Groq"), ("MISTRAL_", "Mistral"), ("DEEPSEEK_", "DeepSeek"),
            ("CLAUDE_", "Anthropic"),
        ]
        return prefixes.first { key.hasPrefix($0.0) }?.1
            ?? String(localized: "cloudAgentReadiness.provider.generic", defaultValue: "the provider")
    }

    static func defaultProvider(for agent: CloudAgentReadinessAgent) -> String {
        providerName(forKey: suggestedKey(for: agent))
    }

    static func credentialLabel(_ entry: CloudAgentReadinessEntry, vaultNames: Set<String>) -> String {
        switch entry.source {
        case .key:
            guard let key = entry.keyName else {
                return String(localized: "cloudAgentReadiness.credential.keyUnnamed", defaultValue: "An API key")
            }
            if vaultNames.contains(key) {
                return String(format: String(localized: "cloudAgentReadiness.credential.vaultKey", defaultValue: "Cloud Secrets: %@"), key)
            }
            return String(format: String(localized: "cloudAgentReadiness.credential.envKey", defaultValue: "Machine env: %@"), key)
        case .login:
            return String(localized: "cloudAgentReadiness.credential.login", defaultValue: "Its own sign-in")
        case .routing:
            return String(localized: "cloudAgentReadiness.credential.routing", defaultValue: "cmux model routing")
        case .config:
            return String(localized: "cloudAgentReadiness.credential.config", defaultValue: "Its own config")
        case .none:
            return String(localized: "cloudAgentReadiness.credential.none", defaultValue: "None")
        }
    }

    static func endpointLabel(_ entry: CloudAgentReadinessEntry) -> String {
        switch entry.endpoint {
        case .provider, .custom:
            return entry.host ?? String(localized: "cloudAgentReadiness.endpoint.providerDefault", defaultValue: "Provider default")
        case .cmux:
            return String(localized: "cloudAgentReadiness.endpoint.routing", defaultValue: "cmux model routing")
        case .unrouted:
            return String(
                format: String(localized: "cloudAgentReadiness.endpoint.unrouted", defaultValue: "%@ (not applied)"),
                entry.host ?? "?"
            )
        case .none:
            return "\u{2014}"
        }
    }

    // MARK: - Status

    private struct Outcome {
        let status: Status
        let detail: String
        let fix: String?
    }

    private static func outcome(_ entry: CloudAgentReadinessEntry, provider: String, machine: String) -> Outcome {
        let syncFix = String(
            format: String(localized: "cloudAgentReadiness.fix.sync", defaultValue: "Apply Cloud Secrets' routing: cmux vm secrets sync %@"),
            machine
        )
        guard entry.installed else {
            return Outcome(
                status: .problem,
                detail: String(localized: "cloudAgentReadiness.detail.notInstalled", defaultValue: "It is not installed on this machine."),
                fix: entry.agent == .gh
                    ? String(format: String(localized: "cloudAgentReadiness.fix.installGh", defaultValue: "Install it: cmux vm exec %@ -- sudo apt-get install -y gh"), machine)
                    : String(localized: "cloudAgentReadiness.fix.otherAgent", defaultValue: "This image does not include it; start another agent or a new machine.")
            )
        }
        switch entry.source {
        case .key:
            return keyOutcome(entry, provider: provider, machine: machine, syncFix: syncFix)
        case .login:
            return Outcome(
                status: .ready,
                detail: String(localized: "cloudAgentReadiness.detail.login", defaultValue: "Signed in on the machine."),
                fix: nil
            )
        case .config:
            return Outcome(
                status: .ready,
                detail: String(localized: "cloudAgentReadiness.detail.config", defaultValue: "Uses the provider in its own config file."),
                fix: nil
            )
        case .routing:
            if entry.reason == "team-unknown" || entry.reason == nil {
                return Outcome(
                    status: .unknown,
                    detail: String(localized: "cloudAgentReadiness.detail.routingUnchecked", defaultValue: "Uses cmux model routing; your team's account was not checked."),
                    fix: nil
                )
            }
            return Outcome(
                status: .ready,
                detail: String(localized: "cloudAgentReadiness.detail.routing", defaultValue: "Uses your team's account through cmux model routing."),
                fix: nil
            )
        case .none:
            return noneOutcome(entry)
        }
    }

    private static func noneOutcome(_ entry: CloudAgentReadinessEntry) -> Outcome {
        let key = suggestedKey(for: entry.agent)
        let detail: String
        switch entry.reason {
        case "no-team-account":
            detail = String(localized: "cloudAgentReadiness.detail.noTeamAccount", defaultValue: "No API key or sign-in, and your team has no account for it in cmux model routing.")
        case "team-unreachable":
            detail = String(localized: "cloudAgentReadiness.detail.routingUnreachable", defaultValue: "No API key or sign-in, and cmux model routing cannot be reached from the machine.")
        default:
            detail = String(localized: "cloudAgentReadiness.detail.none", defaultValue: "No API key or sign-in: it will stop at a sign-in prompt or an auth error.")
        }
        let fix: String
        if entry.agent == .gh {
            fix = String(localized: "cloudAgentReadiness.fix.addGitHubToken", defaultValue: "Add GH_TOKEN: cmux vm secrets import --gh")
        } else {
            fix = String(
                format: String(localized: "cloudAgentReadiness.fix.addKey", defaultValue: "Add %1$@: cmux vm secrets set %1$@"),
                key
            )
        }
        return Outcome(status: .problem, detail: detail, fix: fix)
    }

    private static func keyOutcome(_ entry: CloudAgentReadinessEntry, provider: String, machine: String, syncFix: String) -> Outcome {
        let key = entry.keyName ?? suggestedKey(for: entry.agent)
        let replaceFix = String(
            format: String(localized: "cloudAgentReadiness.fix.replaceKey", defaultValue: "Replace it in Cloud Secrets: cmux vm secrets set %@"),
            key
        )
        switch entry.endpoint {
        case .cmux:
            return Outcome(
                status: .problem,
                detail: String(
                    format: String(localized: "cloudAgentReadiness.detail.keyToRouting", defaultValue: "Your %1$@ would be sent to cmux model routing instead of %2$@."),
                    key, provider
                ),
                fix: syncFix
            )
        case .custom:
            return Outcome(
                status: .ready,
                detail: String(
                    format: String(localized: "cloudAgentReadiness.detail.customEndpoint", defaultValue: "Sends %1$@ to your own endpoint %2$@ (not probed)."),
                    key, entry.host ?? "?"
                ),
                fix: nil
            )
        case .unrouted:
            if let probed = probeOutcome(entry, key: key, provider: provider, machine: machine, replaceFix: replaceFix), probed.status == .problem {
                return probed
            }
            return Outcome(
                status: .attention,
                detail: String(
                    format: String(localized: "cloudAgentReadiness.detail.unrouted", defaultValue: "%1$@'s endpoint is not pinned beside %2$@ yet, so cmux model routing could take it."),
                    provider, key
                ),
                fix: syncFix
            )
        case .provider, .none:
            if let probed = probeOutcome(entry, key: key, provider: provider, machine: machine, replaceFix: replaceFix) {
                return probed
            }
            return Outcome(
                status: .ready,
                detail: String(
                    format: String(localized: "cloudAgentReadiness.detail.keyDirect", defaultValue: "Sends %1$@ to %2$@ directly."),
                    key, provider
                ),
                fix: nil
            )
        }
    }

    /// nil when there is no probe answer to report.
    private static func probeOutcome(
        _ entry: CloudAgentReadinessEntry,
        key: String,
        provider: String,
        machine: String,
        replaceFix: String
    ) -> Outcome? {
        switch entry.probe {
        case .notRun, .unsupported:
            return nil
        case .skipped:
            return Outcome(
                status: .unknown,
                detail: String(
                    format: String(localized: "cloudAgentReadiness.detail.probeSkipped", defaultValue: "%@ has characters the check does not send, so it was not tested."),
                    key
                ),
                fix: nil
            )
        case .unreachable:
            return Outcome(
                status: .attention,
                detail: String(
                    format: String(localized: "cloudAgentReadiness.detail.unreachable", defaultValue: "The machine could not reach %@ to test the key."),
                    provider
                ),
                fix: String(
                    format: String(localized: "cloudAgentReadiness.fix.network", defaultValue: "Check the machine's network policy: cmux vm network %@"),
                    machine
                )
            )
        case .status(let code):
            switch code {
            case 200..<300:
                return Outcome(
                    status: .ready,
                    detail: String(
                        format: String(localized: "cloudAgentReadiness.detail.keyAccepted", defaultValue: "%1$@ accepted %2$@."),
                        provider, key
                    ),
                    fix: nil
                )
            case 401, 403:
                return Outcome(
                    status: .problem,
                    detail: String(
                        format: String(localized: "cloudAgentReadiness.detail.keyRejected", defaultValue: "Key rejected by %1$@ (%2$ld)."),
                        provider, code
                    ),
                    fix: replaceFix
                )
            case 429:
                return Outcome(
                    status: .attention,
                    detail: String(
                        format: String(localized: "cloudAgentReadiness.detail.rateLimited", defaultValue: "%1$@ is rate limiting %2$@ (429); it may be out of credit."),
                        provider, key
                    ),
                    fix: nil
                )
            default:
                return Outcome(
                    status: .attention,
                    detail: String(
                        format: String(localized: "cloudAgentReadiness.detail.probeStatus", defaultValue: "%1$@ answered HTTP %2$ld when testing the key."),
                        provider, code
                    ),
                    fix: nil
                )
            }
        }
    }
}

extension CloudAgentReadinessAssessment {
    /// The one warning line `vm agent` prints before launching, or nil.
    public var preLaunchWarning: String? {
        guard warnsBeforeLaunch else { return nil }
        let name = Self.displayName(entry.agent)
        if let fix {
            return String(
                format: String(localized: "cloudAgentReadiness.preLaunch.withFix", defaultValue: "Warning: %1$@ may not start: %2$@ Fix: %3$@"),
                name, detail, fix
            )
        }
        return String(
            format: String(localized: "cloudAgentReadiness.preLaunch", defaultValue: "Warning: %1$@ may not start: %2$@"),
            name, detail
        )
    }
}
