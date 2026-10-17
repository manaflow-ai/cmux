@testable import CmuxCloud
import Foundation
import Testing

/// The readiness script's output becomes rows, and rows become one status, one
/// detail, and at most one fix, the same for `cmux vm doctor`, the pre-launch
/// warning, and the app's Agents section. The script itself is exercised in
/// web/tests/vm-agent-readiness.test.ts.
@Suite struct CloudAgentReadinessTests {
    private let sample = """
    cmux-agent-readiness v1 plane=1 auth=1
    agent=claude installed=1 version=2.1.300 source=key key=ANTHROPIC_API_KEY mode=team reason=team-account endpoint=provider host=api.anthropic.com probe=401 helper=-
    agent=codex installed=1 version=0.162.1 source=none key=- mode=own reason=no-team-account endpoint=none host=- probe=- helper=-
    agent=opencode installed=1 version=- source=routing key=- mode=team reason=team-account endpoint=cmux host=coderouter.cmux.internal probe=- helper=-
    agent=pi installed=0 version=- source=none key=- mode=- reason=- endpoint=none host=- probe=- helper=-
    agent=gh installed=1 version=- source=key key=GH_TOKEN mode=- reason=- endpoint=provider host=api.github.com probe=200 helper=0
    cmux-agent-readiness end
    """

    // MARK: - Request

    @Test
    func commandCarriesOnlyTheScriptAndItsWords() {
        let request = CloudAgentReadinessRequest(agent: .codex, probe: true)
        #expect(request.command.hasPrefix("sh -c '"))
        #expect(request.command.hasSuffix(" cmux-agent-readiness codex 1 0"))
        #expect(request.execTimeoutMs == 60_000)
        #expect(CloudAgentReadinessRequest().command.hasSuffix(" cmux-agent-readiness all 0 0"))
    }

    @Test
    func fastNeverProbes() {
        let request = CloudAgentReadinessRequest(agent: .claude, probe: true, fast: true)
        #expect(!request.probe)
        #expect(request.execTimeoutMs <= 5_000)
        #expect(request.command.hasSuffix(" cmux-agent-readiness claude 0 1"))
    }

    @Test
    func gitIsTheGitHubRow() {
        #expect(CloudAgentReadinessAgent(argument: "git") == .gh)
        #expect(CloudAgentReadinessAgent(argument: " Claude ") == .claude)
        #expect(CloudAgentReadinessAgent(argument: "cursor") == nil)
    }

    // MARK: - Parsing

    @Test
    func parsesEveryRow() throws {
        let report = try #require(CloudAgentReadinessReport(output: "noise from a login shell\n" + sample + "\n"))
        #expect(report.hasModelRouting)
        #expect(report.hasSignInModes)
        #expect(report.entries.map(\.agent) == [.claude, .codex, .opencode, .pi, .gh])
        let claude = report.entries[0]
        #expect(claude.installed)
        #expect(claude.version == "2.1.300")
        #expect(claude.source == .key)
        #expect(claude.keyName == "ANTHROPIC_API_KEY")
        #expect(claude.mode == "team")
        #expect(claude.reason == "team-account")
        #expect(claude.endpoint == .provider)
        #expect(claude.host == "api.anthropic.com")
        #expect(claude.probe == .status(401))
        #expect(claude.gitCredentialHelper == nil)
        #expect(report.entries[1].keyName == nil)
        #expect(report.entries[1].version == "0.162.1")
        #expect(report.entries[3].installed == false)
        #expect(report.entries[4].gitCredentialHelper == false)
    }

    @Test
    func anIncompleteAnswerIsNoAnswer() {
        #expect(CloudAgentReadinessReport(output: "") == nil)
        #expect(CloudAgentReadinessReport(output: "sh: 1: Syntax error") == nil)
        let truncated = sample.components(separatedBy: "\n").dropLast().joined(separator: "\n")
        #expect(CloudAgentReadinessReport(output: truncated) == nil)
    }

    @Test
    func strayOrMalformedFieldsNeverBecomeText() throws {
        let output = """
        cmux-agent-readiness v1 plane=0 auth=0
        agent=claude installed=1 version=1.0 source=key key=not-a-name mode=team reason=x endpoint=custom host=evil<script> probe=abc helper=-
        agent=nobody installed=1 source=key endpoint=provider
        agent=codex installed=1 source=sometimes endpoint=provider
        agent=claude installed=0 source=none endpoint=none
        a line without fields
        cmux-agent-readiness end
        """
        let report = try #require(CloudAgentReadinessReport(output: output))
        #expect(!report.hasModelRouting)
        #expect(report.entries.count == 1, "unknown agents and sources are dropped; the first row of an agent wins")
        let claude = report.entries[0]
        #expect(claude.keyName == nil)
        #expect(claude.host == nil)
        #expect(claude.probe == .notRun)
    }

    @Test
    func probeWords() throws {
        func probe(_ word: String) throws -> CloudAgentReadinessEntry.Probe {
            let output = "cmux-agent-readiness v1 plane=1 auth=1\nagent=gh installed=1 source=key key=GH_TOKEN endpoint=provider probe=\(word)\ncmux-agent-readiness end"
            return try #require(CloudAgentReadinessReport(output: output)?.entries.first).probe
        }
        #expect(try probe("unreachable") == .unreachable)
        #expect(try probe("skipped") == .skipped)
        #expect(try probe("unsupported") == .unsupported)
        #expect(try probe("-") == .notRun)
        #expect(try probe("999") == .notRun)
        #expect(try probe("429") == .status(429))
    }

    // MARK: - Assessment

    private func assess(_ entry: CloudAgentReadinessEntry, vault: Set<String> = []) -> CloudAgentReadinessAssessment {
        CloudAgentReadinessAssessment(entry: entry, machine: "brave-otter", vaultNames: vault)
    }

    @Test
    func rejectedKeyNamesTheProviderAndTheReplaceCommand() {
        let entry = CloudAgentReadinessEntry(
            agent: .claude, installed: true, source: .key, keyName: "ANTHROPIC_API_KEY",
            endpoint: .provider, host: "api.anthropic.com", probe: .status(401)
        )
        let assessment = assess(entry, vault: ["ANTHROPIC_API_KEY"])
        #expect(assessment.status == .problem)
        #expect(assessment.credential == "Cloud Secrets: ANTHROPIC_API_KEY")
        #expect(assessment.endpoint == "api.anthropic.com")
        #expect(assessment.detail == "Key rejected by Anthropic (401).")
        #expect(assessment.fix == "Replace it in Cloud Secrets: cmux vm secrets set ANTHROPIC_API_KEY")
        #expect(assessment.warnsBeforeLaunch)
    }

    @Test
    func acceptedKeyIsReady() {
        let entry = CloudAgentReadinessEntry(
            agent: .codex, installed: true, source: .key, keyName: "OPENAI_API_KEY",
            endpoint: .provider, host: "api.openai.com", probe: .status(200)
        )
        let assessment = assess(entry)
        #expect(assessment.status == .ready)
        #expect(assessment.statusLabel == "Key works")
        #expect(assessment.credential == "Machine env: OPENAI_API_KEY")
        #expect(assessment.fix == nil)
        #expect(assessment.preLaunchWarning == nil)
    }

    @Test
    func noCredentialSaysWhichKeyToAdd() {
        let codex = assess(CloudAgentReadinessEntry(agent: .codex, installed: true, source: .none, mode: "own", reason: "no-team-account", endpoint: .none))
        #expect(codex.status == .problem)
        #expect(codex.credential == "None")
        #expect(codex.fix == "Add OPENAI_API_KEY: cmux vm secrets set OPENAI_API_KEY")
        #expect(codex.detail.contains("no account"))
        let warning = codex.preLaunchWarning
        #expect(warning?.hasPrefix("Warning: Codex may not start: ") == true)
        #expect(warning?.hasSuffix("Fix: Add OPENAI_API_KEY: cmux vm secrets set OPENAI_API_KEY") == true)

        let gh = assess(CloudAgentReadinessEntry(agent: .gh, installed: true, source: .none, endpoint: .none))
        #expect(gh.fix == "Add GH_TOKEN: cmux vm secrets import --gh")
    }

    @Test
    func aKeyBoundForModelRoutingIsAProblemFixedBySync() {
        let entry = CloudAgentReadinessEntry(
            agent: .codex, installed: true, source: .key, keyName: "OPENAI_API_KEY",
            endpoint: .cmux, host: "coderouter.cmux.internal"
        )
        let assessment = assess(entry)
        #expect(assessment.status == .problem)
        #expect(assessment.endpoint == "cmux model routing")
        #expect(assessment.detail == "Your OPENAI_API_KEY would be sent to cmux model routing instead of OpenAI.")
        #expect(assessment.fix == "Apply Cloud Secrets' routing: cmux vm secrets sync brave-otter")
    }

    @Test
    func unroutedKeyNeedsAttentionUnlessTheProbeRejectedIt() {
        let unrouted = CloudAgentReadinessEntry(
            agent: .claude, installed: true, source: .key, keyName: "ANTHROPIC_API_KEY",
            endpoint: .unrouted, host: "api.anthropic.com"
        )
        #expect(assess(unrouted).status == .attention)
        #expect(assess(unrouted).fix == "Apply Cloud Secrets' routing: cmux vm secrets sync brave-otter")
        #expect(!assess(unrouted).warnsBeforeLaunch)
        let rejected = CloudAgentReadinessEntry(
            agent: .claude, installed: true, source: .key, keyName: "ANTHROPIC_API_KEY",
            endpoint: .unrouted, host: "api.anthropic.com", probe: .status(403)
        )
        #expect(assess(rejected).status == .problem)
    }

    @Test
    func routingAndSignInsAreReady() {
        let routing = assess(CloudAgentReadinessEntry(agent: .opencode, installed: true, source: .routing, mode: "team", reason: "team-account", endpoint: .cmux))
        #expect(routing.status == .ready)
        #expect(routing.credential == "cmux model routing")
        let unchecked = assess(CloudAgentReadinessEntry(agent: .opencode, installed: true, source: .routing, mode: "team", reason: "team-unknown", endpoint: .cmux))
        #expect(unchecked.status == .unknown)
        #expect(!unchecked.warnsBeforeLaunch)
        let login = assess(CloudAgentReadinessEntry(agent: .claude, installed: true, source: .login, endpoint: .provider, host: "api.anthropic.com"))
        #expect(login.status == .ready)
        #expect(login.credential == "Its own sign-in")
    }

    @Test
    func probeTroubleIsAttentionWithANetworkFix() {
        let unreachable = assess(CloudAgentReadinessEntry(
            agent: .gh, installed: true, source: .key, keyName: "GH_TOKEN", endpoint: .provider, host: "api.github.com", probe: .unreachable
        ))
        #expect(unreachable.status == .attention)
        #expect(unreachable.fix == "Check the machine's network policy: cmux vm network brave-otter")
        let limited = assess(CloudAgentReadinessEntry(
            agent: .claude, installed: true, source: .key, keyName: "ANTHROPIC_API_KEY", endpoint: .provider, probe: .status(429)
        ))
        #expect(limited.status == .attention)
    }

    @Test
    func notInstalled() {
        let pi = assess(CloudAgentReadinessEntry(agent: .pi, installed: false, source: .none, endpoint: .none))
        #expect(pi.status == .problem)
        #expect(pi.statusLabel == "Not installed")
    }

    @Test
    func customEndpointIsTrustedAndNamedByHost() {
        let custom = assess(CloudAgentReadinessEntry(
            agent: .claude, installed: true, source: .key, keyName: "ANTHROPIC_API_KEY", endpoint: .custom, host: "proxy.example.com"
        ))
        #expect(custom.status == .ready)
        #expect(custom.endpoint == "proxy.example.com")
        #expect(custom.detail.contains("not probed"))
    }
}
