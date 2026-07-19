import Testing
@testable import CmuxTerminalCore

@Suite
struct AgentTerminalStateClassifierTests {
    private let classifier = AgentTerminalStateClassifier()

    @Test(arguments: [
        ("pi", "pi"),
        ("omp", "omp"),
        ("copilot", "copilot"),
        ("devin", "devin"),
        ("kimi", "kimi"),
        ("hermes-agent", "hermes-agent"),
        ("qoder", "qoder"),
        ("droid", "droid"),
        ("opencode", "opencode"),
        ("kilo-code", "kilo"),
        ("mastracode", "mastracode"),
        ("claude", "claude-code"),
        ("codex", "codex"),
        ("cursor-agent", "cursor-agent"),
        ("amp", "amp"),
        ("grok", "grok"),
        ("antigravity", "antigravity"),
        ("kiro-cli", "kiro"),
        ("maki", "maki"),
        ("gemini", "gemini"),
        ("cline", "cline"),
    ])
    func recognizesEveryRequiredFamily(executable: String, expectedID: String) throws {
        let profile = try #require(classifier.recognize(process(executable: executable)))
        #expect(profile.id == expectedID)
    }

    @Test(arguments: [
        "pi", "omp", "copilot", "devin", "kimi", "hermes-agent", "qoder", "droid",
        "opencode", "kilo", "mastracode", "claude-code", "codex", "cursor-agent", "amp",
        "grok", "antigravity", "kiro", "maki", "gemini", "cline",
    ])
    func knownFamiliesConservativelyFallBackToIdle(familyID: String) {
        let classification = classifier.classify(screen(familyID: familyID, text: ""))
        #expect(classification.state == .idle)
    }

    @Test
    func unknownFamilyIsUnknown() {
        let classification = classifier.classify(screen(familyID: "unsupported", text: "Working..."))
        #expect(classification.state == .unknown)
        #expect(classification.familyID == nil)
    }

    @Test
    func recognizesAgentsHiddenByGenericRuntimes() throws {
        let node = process(executable: "node", arguments: ["node", "/opt/@openai/codex/bin/codex.js"])
        #expect(try #require(classifier.recognize(node)).id == "codex")

        let bun = process(executable: "bun", arguments: ["bun", "/app/opencode/dist/index.js"])
        #expect(try #require(classifier.recognize(bun)).id == "opencode")
    }

    @Test
    func recognizesAgentsAfterKnownWrapperOptions() throws {
        let npx = process(
            executable: "npx",
            arguments: ["npx", "-y", "@anthropic-ai/claude-code"]
        )
        #expect(try #require(classifier.recognize(npx)).id == "claude-code")

        let uvx = process(
            executable: "uvx",
            arguments: ["uvx", "--from", "kimi-cli", "kimi-code"]
        )
        #expect(try #require(classifier.recognize(uvx)).id == "kimi")

        let nested = process(
            executable: "npx",
            arguments: ["npx", "-y", "uvx", "--from", "kimi-cli", "kimi-code"]
        )
        #expect(try #require(classifier.recognize(nested)).id == "kimi")
    }

    @Test
    func recognizesAgentsAfterPackageManagerSubcommands() throws {
        let npmExec = process(
            executable: "npm",
            arguments: ["npm", "exec", "--", "@anthropic-ai/claude-code"]
        )
        #expect(try #require(classifier.recognize(npmExec)).id == "claude-code")

        let npmX = process(
            executable: "npm",
            arguments: ["npm", "x", "--", "@openai/codex"]
        )
        #expect(try #require(classifier.recognize(npmX)).id == "codex")

        let pnpmDlx = process(
            executable: "pnpm",
            arguments: ["pnpm", "dlx", "@anthropic-ai/claude-code"]
        )
        #expect(try #require(classifier.recognize(pnpmDlx)).id == "claude-code")
    }

    @Test
    func recognizesOnlyTheRovoDevAcliSubcommand() throws {
        let rovo = process(
            executable: "acli",
            arguments: ["acli", "rovodev", "run"]
        )
        #expect(try #require(classifier.recognize(rovo)).id == "rovodev")

        let jira = process(
            executable: "acli",
            arguments: ["acli", "jira", "issue", "list"]
        )
        #expect(classifier.recognize(jira) == nil)
    }

    @Test
    func exactWrappedAgentExecutableOutranksInheritedHint() throws {
        let wrapped = AgentTerminalProcessSnapshot(
            identity: identity,
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/Users/test/.bun/bin/claude", "--resume", "session-id"],
            environment: ["CMUX_AGENT_LAUNCH_KIND": "codex"]
        )

        #expect(try #require(classifier.recognize(wrapped)).id == "claude-code")
    }

    @Test
    func recognizesCodexExecutableBehindGenericWrappers() throws {
        let node = process(
            executable: "node",
            arguments: ["node", "/Users/test/.bun/bin/codex", "fork", "session-id"]
        )
        #expect(try #require(classifier.recognize(node)).id == "codex")

        let bun = process(
            executable: "bun",
            arguments: ["bun", "/Users/test/.bun/bin/codex", "resume", "session-id"]
        )
        #expect(try #require(classifier.recognize(bun)).id == "codex")
    }

    @Test
    func wrappedPromptTextCannotImpersonateAnAgent() {
        let wrapped = process(
            executable: "node",
            arguments: ["node", "/app/tool.js", "--prompt", "please run @openai/codex next"]
        )

        #expect(classifier.recognize(wrapped) == nil)
    }

    @Test
    func wrappedRecognitionOnlyInspectsTheLaunchTarget() {
        let wrapped = process(
            executable: "node",
            arguments: ["node", "/tmp/tool.js", "/tmp/codex"]
        )

        #expect(classifier.recognize(wrapped) == nil)
    }

    @Test
    func versionedPythonRuntimeRecognizesKimiProcessTitle() throws {
        let kimi = process(executable: "python3.14", arguments: ["Kimi Code"])
        #expect(try #require(classifier.recognize(kimi)).id == "kimi")
    }

    @Test
    func unrecognizedProcessGenerationRemainsEligibleForRecognition() {
        let identity = AgentTerminalProcessIdentity(
            pid: 42,
            startSeconds: 100,
            startMicroseconds: 200,
            runtimeGeneration: 3
        )
        var cache = AgentTerminalRecognitionCache()

        cache.store(identity: identity, familyID: nil)
        #expect(cache.requiresSnapshot(for: identity))

        cache.store(identity: identity, familyID: "kimi")
        #expect(!cache.requiresSnapshot(for: identity))
        #expect(cache.familyID(for: identity) == "kimi")
    }

    @Test
    func scopedHintRecognizesOpaqueWrapper() throws {
        let wrapped = AgentTerminalProcessSnapshot(
            identity: identity,
            executablePath: "/usr/local/bin/sandbox-exec",
            arguments: ["sandbox-exec", "guest"],
            environment: ["CMUX_AGENT": "claude_code"]
        )
        #expect(try #require(classifier.recognize(wrapped)).id == "claude-code")
    }

    @Test
    func directExecutableOutranksInheritedLaunchHint() throws {
        let direct = AgentTerminalProcessSnapshot(
            identity: identity,
            executablePath: "/usr/local/bin/codex",
            arguments: ["codex"],
            environment: ["CMUX_AGENT_LAUNCH_KIND": "claude"]
        )
        #expect(try #require(classifier.recognize(direct)).id == "codex")
    }

    @Test
    func launchHintRecognizesOpaqueWrapperOnlyAfterDirectIdentityMisses() throws {
        let wrapped = AgentTerminalProcessSnapshot(
            identity: identity,
            executablePath: "/usr/bin/sandbox-exec",
            arguments: ["sandbox-exec", "opaque-wrapper"],
            environment: ["CMUX_AGENT_LAUNCH_KIND": "claude"]
        )
        #expect(try #require(classifier.recognize(wrapped)).id == "claude-code")
    }

    @Test
    func shellArgumentsAndInheritedHintsCannotImpersonateAnAgent() {
        let shell = AgentTerminalProcessSnapshot(
            identity: identity,
            executablePath: "/bin/zsh",
            arguments: ["zsh", "-c", "echo codex opencode"],
            environment: ["CMUX_AGENT_LAUNCH_KIND": "claude"]
        )
        #expect(classifier.recognize(shell) == nil)
    }

    @Test
    func versionedAgentPathRecognizesWithoutGenericArgumentHost() throws {
        let versioned = AgentTerminalProcessSnapshot(
            identity: identity,
            executablePath: "/Users/test/.local/share/claude/versions/2.1.212",
            arguments: ["2.1.212"]
        )
        #expect(try #require(classifier.recognize(versioned)).id == "claude-code")
    }

    @Test
    func nestedTmuxIsAnIntentionalBoundary() {
        let nested = process(executable: "tmux", arguments: ["tmux", "new", "codex"])
        #expect(classifier.recognize(nested) == nil)
    }

    @Test
    func currentAgentFixturesClassifyWorkingAndBlocked() {
        #expect(classifier.classify(screen(
            familyID: "claude-code",
            text: "⠋ Editing files (12s · esc to interrupt)"
        )).state == .working)
        #expect(classifier.classify(screen(
            familyID: "codex",
            text: "Working (8s • esc to interrupt)"
        )).state == .working)
        #expect(classifier.classify(screen(
            familyID: "pi",
            text: "⠙ Working..."
        )).state == .working)
        #expect(classifier.classify(screen(
            familyID: "opencode",
            text: "━━━ esc interrupt"
        )).state == .working)
        #expect(classifier.classify(screen(
            familyID: "cursor-agent",
            text: "⠋ Running · 4.2k tokens"
        )).state == .working)
        #expect(classifier.classify(screen(
            familyID: "gemini",
            text: "Enter your API key"
        )).state == .blocked)
        #expect(classifier.classify(screen(
            familyID: "kimi",
            text: "Authorization failed\nSession may have expired\nType /login to re-authenticate"
        )).state == .blocked)
        #expect(classifier.classify(screen(
            familyID: "claude-code",
            text: "This command requires approval\nDo you want to proceed?\n1. Yes\n2. No"
        )).state == .blocked)
        #expect(classifier.classify(screen(
            familyID: "codex",
            text: "Would you like to run the following command?\n1. Yes\n2. No"
        )).state == .blocked)
    }

    @Test
    func exactBlockedPromptMustOccupyItsOwnRenderedLine() {
        #expect(classifier.classify(screen(
            familyID: "gemini",
            text: "Enter your API key"
        )).state == .blocked)
        #expect(classifier.classify(screen(
            familyID: "gemini",
            text: "The setup guide says to enter your API key before continuing."
        )).state == .idle)
    }

    @Test
    func geminiAPIKeyDialogRequiresItsCorroboratingPromptRows() {
        let capturedInteraction = [
            "Gemini CLI v0.51.0",
            "Enter Gemini API Key",
            "Please enter your Gemini API key. It will be securely stored in your system keychain.",
            "Paste your API key here",
            "(Press Enter to submit, Esc to cancel, Ctrl+C to clear stored key)",
        ].joined(separator: "\n")
        #expect(classifier.classify(screen(familyID: "gemini", text: capturedInteraction)).state == .blocked)
    }

    @Test
    func kimiUpdateDialogIgnoresRenderedColumnSpacing() {
        let capturedInteraction = [
            "kimi-cli update available",
            "[Enter]  Upgrade now  (uv tool upgrade kimi-cli)",
            "[q]      Not now, remind me next time",
            "[s]      Skip reminders for version 1.47.0",
        ].joined(separator: "\n")
        #expect(classifier.classify(screen(familyID: "kimi", text: capturedInteraction)).state == .blocked)
    }

    @Test
    func stalePiSpinnerAboveIdleComposerDoesNotRemainWorking() {
        let capturedTail = [
            "Read only. Inspect the repository for 20 seconds.",
            "",
            "⠇ Working...",
            "",
            "────────────────────────────────────────",
            "",
            "Error: No API key for provider: openai-codex",
            "",
            "Warning: cmux Pi integration warning",
            "",
            "Warning: cmux Pi integration warning",
            "",
            "────────────────────────────────────────",
            " ",
            "────────────────────────────────────────",
            "~/project (feat-agent-terminal-state-detection)",
            "$0.000 (sub) 0.0%/272k (auto) (openai-codex) gpt-5.4-mini",
            "",
        ].joined(separator: "\n")
        #expect(classifier.classify(screen(familyID: "pi", text: capturedTail)).state == .idle)
    }

    @Test
    func codexMultilineApprovalPromptRemainsInsideBlockedEvidenceWindow() {
        let capturedInteraction = [
            "Would you like to run the following command?",
            "",
            "Environment: local",
            "",
            "$ touch /tmp/cmux-agent-state-blocked-proof",
            "",
            "1. Yes, proceed (y)",
            "2. Yes, and don't ask again (p)",
            "3. No, and tell Codex what to do differently (esc)",
            "",
            "Press enter to confirm or esc to cancel",
        ].joined(separator: "\n")
        #expect(classifier.classify(screen(familyID: "codex", text: capturedInteraction)).state == .blocked)
    }

    @Test
    func codexApprovalPromptUsesRenderedRowsInsteadOfVTLineSeparators() {
        let ghosttyRenderedInteraction = [
            "Would you like to run the following command?",
            "",
            "Environment: local",
            "",
            "$ touch /tmp/cmux-agent-state-blocked-proof",
            "",
            "1. Yes, proceed (y)",
            "2. Yes, and don't ask again (p)",
            "3. No, and tell Codex what to do differently (esc)",
            "",
            "Press enter to confirm or esc to cancel",
        ].joined(separator: "\r\n")
        #expect(classifier.classify(screen(familyID: "codex", text: ghosttyRenderedInteraction)).state == .blocked)
    }

    @Test
    func genericWordsAndQuotedQuestionsDoNotCreateActivity() {
        #expect(classifier.classify(screen(
            familyID: "cursor-agent",
            text: "The running process finished without token output"
        )).state == .idle)
        #expect(classifier.classify(screen(
            familyID: "claude-code",
            text: "The documentation says: do you want to proceed"
        )).state == .idle)
    }

    @Test
    func staleScrollbackOutsideLiveTailCannotForceBlocked() {
        let historical = "Permission required\n" + Array(repeating: "completed output", count: 40).joined(separator: "\n")
        #expect(classifier.classify(screen(familyID: "omp", text: historical + "\ncontext 18%" )).state == .idle)
    }

    @Test
    func historyViewerPreservesLastReliableState() {
        let snapshot = AgentTerminalScreenSnapshot(
            processIdentity: identity,
            familyID: "codex",
            liveBottomText: "Session history\nPermission required",
            previousReliableState: .working
        )
        #expect(classifier.classify(snapshot).state == .working)
    }

    @Test
    func historyViewerWithoutPriorStateIsUnknown() {
        #expect(classifier.classify(screen(
            familyID: "codex",
            text: "Session history\nWould you like to run the following command?\nYes\nNo"
        )).state == .unknown)
    }

    @Test
    func lifecycleAuthorityOutranksContradictoryScreenState() {
        let resolver = AgentTerminalAuthorityResolver()
        #expect(resolver.resolve(authoritative: .blocked, screen: .working) == .blocked)
        #expect(resolver.resolve(authoritative: .idle, screen: .working) == .idle)
        #expect(resolver.resolve(authoritative: nil, screen: .working) == .working)
        #expect(resolver.resolve(
            authoritative: .idle,
            screen: .working,
            lifecycleAuthoritative: false
        ) == .working)
    }

    @Test
    func invalidReplacementCatalogCanLeavePriorCatalogIntact() {
        let prior = AgentTerminalProfileCatalog.builtIn
        let duplicate = prior.profiles[0]
        #expect(AgentTerminalProfileCatalog(profiles: [duplicate, duplicate]) == nil)
        #expect(prior.profiles.count >= 26)
    }

    @Test
    func replacementCatalogNormalizesIdentityDataAndRejectsAmbiguity() throws {
        let normalized = try #require(AgentTerminalProfileCatalog(profiles: [profile(
            id: " Example_Agent ",
            executable: " Example "
        )]))
        #expect(normalized.profiles[0].id == "example-agent")
        #expect(normalized.profiles[0].executableBasenames == ["example"])

        #expect(AgentTerminalProfileCatalog(profiles: [
            profile(id: "one", executable: "shared"),
            profile(id: "two", executable: " SHARED "),
        ]) == nil)
        #expect(AgentTerminalProfileCatalog(profiles: [
            profile(id: "empty", executable: "empty", argumentNeedles: [" "]),
        ]) == nil)
        #expect(AgentTerminalProfileCatalog(profiles: [
            profile(id: "empty-group", executable: "empty-group", working: [[]]),
        ]) == nil)
        #expect(AgentTerminalProfileCatalog(profiles: [
            profile(id: "singleton-blocked", executable: "singleton-blocked", blocked: [["approval required"]]),
        ]) == nil)
    }

    private var identity: AgentTerminalProcessIdentity {
        AgentTerminalProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 5, runtimeGeneration: 3)
    }

    private func process(executable: String, arguments: [String]? = nil) -> AgentTerminalProcessSnapshot {
        AgentTerminalProcessSnapshot(
            identity: identity,
            executablePath: "/usr/local/bin/\(executable)",
            arguments: arguments ?? [executable]
        )
    }

    private func screen(familyID: String?, text: String) -> AgentTerminalScreenSnapshot {
        AgentTerminalScreenSnapshot(
            processIdentity: identity,
            familyID: familyID,
            liveBottomText: text
        )
    }

    private func profile(
        id: String,
        executable: String,
        argumentNeedles: [String] = [],
        working: [[String]] = [],
        blocked: [[String]] = []
    ) -> AgentTerminalFamilyProfile {
        AgentTerminalFamilyProfile(
            id: id,
            statusKey: id,
            displayName: id,
            executableBasenames: [executable],
            argumentNeedles: argumentNeedles,
            workingEvidenceGroups: working,
            blockedEvidenceGroups: blocked
        )
    }
}
