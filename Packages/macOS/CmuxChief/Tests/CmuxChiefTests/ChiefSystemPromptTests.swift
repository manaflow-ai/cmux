@testable import CmuxChief
import Foundation
import Testing

/// Chief's system prompt: section order, user files verbatim at the end, and
/// the CLI surface it teaches.
@Suite struct ChiefSystemPromptTests {
    func context() -> ChiefPromptContext {
        ChiefPromptContext(
            userDisplayName: "Ada",
            person: "Ada runs the backend team.\n\n- Likes terse replies.",
            instructions: "Always start agents in a new worktree.",
            memory: "- Machine brave-otter is for builds (m-1, 2026-10-14)",
            harness: "Claude Code",
            model: "claude-opus-5-5",
            cmuxVersion: "0.66.0",
            socketPath: "/tmp/cmux-test.sock",
            chiefHomePath: "/tmp/chief-home",
            workspacesSummary: "workspace:1 api (selected)\nworkspace:2 web",
            currentWorkspaceRef: "workspace:1",
            currentSurfaceRef: "surface:9",
            date: Date(timeIntervalSince1970: 1_792_000_000),
            timeZone: TimeZone(identifier: "UTC") ?? .current
        )
    }

    @Test func userFilesComeLastAndVerbatim() {
        let prompt = ChiefSystemPrompt(context: context()).build()
        #expect(prompt.hasPrefix("You are Chief, Ada's chief of staff inside cmux"))
        #expect(prompt.hasSuffix("Ada runs the backend team.\n\n- Likes terse replies.\n"))
        let order = ["# Voice", "# Your tools", "# Coding agents", "# Cloud machines", "# Settings", "# Memory",
                     "# Environment", "# Workspaces when this conversation started", "# What you remember",
                     "# Ada's instructions for you", "# Ada\n"]
        let positions = order.map { prompt.range(of: $0)?.lowerBound }
        #expect(!positions.contains(nil))
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted())
        #expect(prompt.contains("Always start agents in a new worktree."))
        #expect(prompt.contains("- Machine brave-otter is for builds (m-1, 2026-10-14)"))
    }

    @Test func environmentCarriesSessionFacts() {
        let prompt = ChiefSystemPrompt(context: context()).build()
        #expect(prompt.contains("- Now: Wednesday 2026-10-14 17:46 GMT"))
        #expect(prompt.contains("- cmux: 0.66.0"))
        #expect(prompt.contains("- Socket: /tmp/cmux-test.sock"))
        #expect(prompt.contains("- You run on: Claude Code, model claude-opus-5-5"))
        #expect(prompt.contains("- Chief home: /tmp/chief-home"))
        #expect(prompt.contains("workspace:2 web"))
        #expect(prompt.contains("# Current Chief target"))
        #expect(prompt.contains("This turn was sent from Chief in workspace `workspace:1`."))
        #expect(prompt.contains("Chief surface: surface:9"))
        #expect(prompt.contains("--workspace workspace:1 --url <url> --focus false"))
        #expect(prompt.contains("verify with\n`cmux tree --all --json`"))
    }

    @Test func aMissingCommandIsNotReadAsSignedOut() {
        let prompt = ChiefSystemPrompt(context: context()).build()
        #expect(prompt.contains("`command not found`"))
        #expect(prompt.contains("login-shell `PATH`"))
        #expect(!prompt.contains("same `PATH` as the user's terminal"))
        #expect(prompt.contains("`command -v <tool>`"))
        #expect(prompt.contains("`gh auth status`"))
    }

    /// The Cloud computer-use loop verified on a desktop machine: `cua-driver call`
    /// needs its daemon and the desktop environment, a screenshot is written to a
    /// file and pulled here to be looked at, and the user watches the desktop.
    @Test func teachesTheCloudComputerUseLoop() {
        let prompt = ChiefSystemPrompt(context: context()).build()
        for step in [
            "cmux vm open <machine>:desktop", "capabilities.desktop",
            ". /etc/cmux/desktop-env.sh", "export HOME=/home/cmux",
            "setsid -f cua-driver serve", "cua-driver call <tool> '<json>'",
            "\"screenshot_out_file\"", "cmux vm pull <machine> /home/cmux/.cache/chief/screen.png",
            "list_windows", "launch_app", "cua-driver describe <tool>",
            "cua-driver mcp",
        ] {
            #expect(prompt.contains(step), "missing \(step)")
        }
        #expect(!prompt.contains("From a machine terminal, run `cua-driver doctor`"))
        // Typed text often has an apostrophe; the daemon may serve a machine agent; the
        // agent's cua-driver tool is written at its first launch, so it is not probed.
        #expect(prompt.contains("beyond your own shell's single quotes"))
        #expect(prompt.contains("Leave the driver's daemon running"))
        #expect(!prompt.contains("cua-driver stop"))
        #expect(!prompt.contains("grep -q cua-driver"))
    }

    @Test func emptyContextOmitsOptionalSections() {
        let prompt = ChiefSystemPrompt(context: ChiefPromptContext(date: Date(timeIntervalSince1970: 0),
                                                                        timeZone: TimeZone(identifier: "UTC") ?? .current)).build()
        #expect(prompt.hasPrefix("You are Chief, the user's chief of staff inside cmux"))
        #expect(prompt.contains("(nothing saved yet)"))
        #expect(!prompt.contains("# Workspaces when this conversation started"))
        #expect(!prompt.contains("instructions for you"))
        #expect(!prompt.contains("- Socket:"))
        #expect(prompt.hasSuffix("(nothing saved yet)\n"))
    }

    @Test func staticPrefixDoesNotDependOnTheSession() {
        var other = context()
        other.date = Date(timeIntervalSince1970: 1_800_000_000)
        other.memory = "- something else"
        let a = ChiefSystemPrompt(context: context()).build()
        let b = ChiefSystemPrompt(context: other).build()
        let prefix = { (text: String) in String(text[..<(text.range(of: "# Environment")?.lowerBound ?? text.endIndex)]) }
        #expect(prefix(a) == prefix(b))
    }

    @Test func teachesTheVerifiedCommands() {
        let prompt = ChiefSystemPrompt(context: context()).build()
        for command in [
            "cmux workspace create --name", "cmux workspace list --json", "cmux workspace rename workspace:N --title",
            "cmux workspace close workspace:N", "cmux read-screen --workspace workspace:N", "cmux send-key",
            "cmux set-status <key>", "cmux set-progress", "cmux notify --title", "cmux agent message workspace:N",
            "cmux sidebar-state --workspace", "cmux current --json",
            "cmux vm new --detach", "cmux vm wait <machine> --wake", "cmux vm push <machine> <local-dir> work/<slug>",
            "cmux vm workspace new <machine> --name \"<short title>\" --no-open --json", "cmux vm tree <machine> --json",
            "cmux vm terminal send <machine> <term>", "--keys enter", "cmux vm terminal read <machine> <term>",
            "cmux vm terminal wait <machine> <term> --pattern",
            "cmux settings path", "cmux config set", "cmux config doctor", "cmux reload-config",
            "cmux chief memory add", "cmux chief memory list", "cmux chief memory forget <id>",
        ] {
            #expect(prompt.contains(command), "missing \(command)")
        }
        // Rules from the Cloud dispatch playbook.
        #expect(prompt.contains("never reuse one"))
        // Code reaches a machine by a clone there when it can; a push is small, sized first and asked about past 1 GB.
        for rule in [
            "cmux vm exec --timeout 600 <machine> -- git clone --depth 1 --branch <branch> <url> /home/cmux/work/<slug>",
            "du -sh <dir>", "--exclude .build --exclude DerivedData --exclude node_modules --exclude target",
            "never push more than about 1 GB without asking", "Use the absolute `/home/cmux/work/<slug>` destination",
        ] {
            #expect(prompt.contains(rule), "missing \(rule)")
        }
        #expect(prompt.contains("`--here`"))
    }

    @Test func teachesQuietBatchedJSONReadsAndShortReplies() {
        let prompt = ChiefSystemPrompt(context: context()).build()
        for rule in [
            "one to three short, plain sentences", "No Markdown headers or tables", "Don't narrate tool use",
            "Prefer plain `cmux` commands with `--json`", "cmux tree --all --json", "Batch what you need",
            "approval card",
        ] {
            #expect(prompt.contains(rule), "missing \(rule)")
        }
    }

    @Test func snapshotFeedsTheContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-prompt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = ChiefMemory(paths: ChiefMemoryPaths(home: ChiefHome(root: root)))
        try memory.ensureDefaults()
        try memory.add("Uses pnpm", source: "cli")
        var context = ChiefPromptContext(date: Date(timeIntervalSince1970: 0))
        context.apply(memory.snapshot())
        let prompt = ChiefSystemPrompt(context: context).build()
        #expect(prompt.contains("- Uses pnpm ("))
        #expect(prompt.contains("Act without asking for safe operations"))
        #expect(!prompt.contains("<!--"))
    }
}
