@testable import CmuxChief
import Foundation
import Testing

@Suite struct ChiefToolPolicyTests {
    // MARK: Auto-allowed

    static let allowed: [String] = [
        // cmux reads and everyday writes
        "cmux list-workspaces",
        "cmux tree --all",
        "cmux workspace list --json",
        "cmux current --json",
        "cmux notify --title hi",
        "cmux workspace create --name Build --cwd ~/src/app --command 'codex --yolo'",
        "cmux workspace rename workspace:2 --title \"API server\"",
        "cmux send --workspace workspace:2 --surface surface:3 \"npm test; echo done\\n\"",
        "cmux send-key --workspace workspace:2 --surface surface:3 enter",
        "cmux read-screen --workspace workspace:2 --lines 80",
        "cmux agent message workspace:2 \"please close the PR when done\"",
        "cmux vm ls --json",
        "cmux vm tree brave-otter --json",
        "cmux cloud ls --json",
        "cmux vm terminal read brave-otter term_1",
        "cmux chief memory add \"Uses worktrees under ~/src\"",
        "cmux chief memory forget 3",
        "cmux config set app.theme dark",
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
        "ls -la",
        "pwd",
        "date",
        "which cmux",
        "cat README.md | head -20",
        "grep -rn TODO Sources | wc -l",
        "rg -l ChiefToolPolicy",
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
