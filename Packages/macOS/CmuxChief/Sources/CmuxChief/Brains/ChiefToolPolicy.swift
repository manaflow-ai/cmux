import Foundation

/// What a Chief may do without asking, and how its tool calls read in Home.
///
/// Auto-allowed without an approval card:
///
/// - Claude Code's `WebSearch` and `ToolSearch`.
/// - `Read`, `Glob` and `Grep` of paths away from credentials
///   (``ChiefSensitivePaths``): `Read` needs an absolute `file_path`, `Glob`
///   and `Grep` an absolute `path` that is not the home folder, an ancestor
///   of it, or an ancestor of a credential folder. `WebFetch` always asks:
///   a fetched URL can carry what the Chief read.
/// - A shell command line whose every simple command is allowed, joined by
///   `|`, `&&`, `||`, `;` or newlines (see ``ChiefShellLexer``). Redirects
///   are limited to `2>&1` and `>/dev/null`; substitution, subshells,
///   backticks, `<`, background `&`, `$` expansion outside single quotes,
///   `$'…'` quoting, brace expansion, globs and tilde expansion ask. The
///   allowed simple commands:
///   - `cmux` read-only commands only (``cmuxReadOnlyCommands``: `tree`,
///     `list-*`, `read-screen`, `vm ls`, …), and none of their words may
///     name a destructive verb or flag (``cmuxWordAsks(_:)``); plus
///     `cmux workspace create` with only naming and placement flags (no
///     `--command`, `--layout` or `--focus true`). Every other `cmux` command
///     (sending text or keys, closing, `vm new`, `vm exec`, `browser eval`,
///     `chief dispatch|send|approve`, `config set`) asks. `chief memory add`
///     runs at once: the transcript shows each saved fact with Undo.
///   - Read-only tools: `ls`, `pwd`, `cat`, `head`, `tail`, `wc`, `which`,
///     `date`, `jq`, `grep`, `cut`, `tr`, `column`; `rg` without `--pre`;
///     `sort` with only listed ordering flags; `uniq` with at most one file;
///     `awk` without `system`, pipes, redirection, `getline` or program
///     files; `sed -n` whose script only prints (`p`, `=`, `l`, `q`, `d`,
///     `n`, `s///` with `gpiI` flags).
///   - Read-only `git` (`status`, `log`, `diff`, `show`, listing `branch`,
///     …) and `gh` (`pr view|list|diff|checks|status`, `issue view|list`,
///     …).
///
/// Everything else (edits, writes, other commands) asks the user. The same
/// check covers Codex's approval requests after unwrapping `zsh -lc '…'`.
enum ChiefToolPolicy {
    /// The options of every approval card, allow first.
    static let approvalOptions = ["Allow", "Deny"]

    /// A card's options for running the full `command` (nil for other prompts): ``approvalOptions``
    /// plus the Always Allow rule a card may offer for it (``ChiefAllowRules/alwaysOption(for:)``),
    /// derived here once from the lexed, untruncated command.
    static func approvalOptions(command: String?) -> [String] {
        guard let command, let always = ChiefAllowRules.alwaysOption(for: unwrapShell(command)) else { return approvalOptions }
        return approvalOptions + [always]
    }

    /// Whether a choice from ``approvalOptions`` grants the call.
    static func isAllow(_ choice: String) -> Bool {
        choice.caseInsensitiveCompare("Allow") == .orderedSame
    }

    /// Whether an approval option refuses (Stop settles a waiting card with it).
    static func isRefusal(_ choice: String) -> Bool {
        ["deny", "decline", "reject", "no", "cancel"].contains(choice.lowercased())
    }

    /// Whether Claude Code's `tool` with `input` runs without asking.
    ///
    /// - Parameters:
    ///   - tool: The tool name from the permission request.
    ///   - input: The tool's input.
    ///   - home: The user's home folder (tests pass a fixed one).
    static func autoAllowsClaudeTool(
        _ tool: String,
        input: ChiefJSON,
        home: String = NSHomeDirectory(),
        allowRules: ChiefAllowRules? = nil
    ) -> Bool {
        let paths = ChiefSensitivePaths(home: home)
        switch tool {
        case "WebSearch", "ToolSearch":
            return true
        case "Read":
            guard let file = input["file_path"]?.string else { return false }
            return paths.allowsRead(file)
        case "Glob", "Grep":
            // No `path` searches the brain's working directory, which may be the home folder.
            guard let root = input["path"]?.string, paths.allowsSearch(root) else { return false }
            let filters = [tool == "Glob" ? input["pattern"]?.string : nil, input["glob"]?.string].compactMap { $0 }
            return !filters.contains(where: paths.patternNamesSecrets)
        case "Bash":
            guard let command = input["command"]?.string else { return false }
            return autoAllowsCommand(command, allowRules: allowRules, home: home)
        default:
            return false
        }
    }

    /// Whether a shell command line runs without asking.
    ///
    /// - Parameter command: The command line, possibly wrapped in `sh -lc '…'`.
    static func autoAllowsCommand(
        _ command: String,
        allowRules: ChiefAllowRules? = nil,
        home: String = NSHomeDirectory()
    ) -> Bool {
        let line = unwrapShell(command)
        guard let stages = ChiefShellLexer.stagesWithPipeInput(of: line), !stages.isEmpty else { return false }
        for (stage, inputFromPipe) in stages {
            // `$HOME`-style expansion could smuggle flags past the checks.
            if stage.contains(where: \.expands) { return false }
            let words = stage.map(\.text)
            // The user's "Always Allow" rules (an approval card's menu) cover their program and subcommand.
            guard autoAllowsSimpleCommand(words, home: home, inputFromPipe: inputFromPipe)
                || (allowRules?.allows(words) ?? false) else { return false }
        }
        return true
    }

    /// Words that make a `cmux` call ask first, wherever they appear in it
    /// (lowercased, the part before any `=`): verbs that close, remove, kill,
    /// quit, wipe, type into terminals, run commands, publish or escalate,
    /// and flags that override a safety check or carry a command. Always
    /// Allow rules and Home's card use the same check (``cmuxWordAsks(_:)``).
    static let cmuxApprovalWords: Set<String> = [
        "close", "rm", "remove", "delete", "destroy", "kill", "quit", "restart", "relaunch", "reset",
        "clear", "clear-history", "cleanup", "ssh-session-cleanup", "uninstall", "logout",
        "sudo", "rpc", "pipe-pane", "respawn-pane", "set-hook",
        "publish", "access", "grant", "ungrant", "upload", "feedback", "promote-template",
        "send", "paste", "paste-buffer", "exec", "run", "eval", "repl", "shell", "ssh", "mosh",
        "approve", "answer", "addscript", "addinitscript",
        "--force", "--yes", "--command", "--eval", "--layout",
        // `vm wait --wake` starts a stopped machine, which bills the user; plain `vm wait` only reads.
        "--wake",
    ]
    /// Prefixes with the same effect (`close-workspace`, `send-key`, `--force=true`).
    static let cmuxApprovalPrefixes = [
        "close-", "kill-", "clear-", "send-", "delete-", "remove-", "--force", "--yes", "--command", "--eval", "--wake",
    ]

    /// Whether one word of a `cmux` call names a destructive or escalating
    /// verb or flag (``cmuxApprovalWords``, ``cmuxApprovalPrefixes``).
    static func cmuxWordAsks(_ word: String) -> Bool {
        let lower = word.lowercased()
        let key = lower.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lower
        return cmuxApprovalWords.contains(key) || cmuxApprovalPrefixes.contains { key.hasPrefix($0) }
    }

    /// The `cmux` commands that only read, checked against `cmux help` and
    /// each command's `--help`. A call runs without asking when its words
    /// start with one of these exactly (no global options before it) and no
    /// later word trips ``cmuxWordAsks(_:)``. Commands that print secrets
    /// (`workspace env`, `vm env ls --show`) or write on a flag
    /// (`agent inbox --mark-read`, `workspace status set`) are left out.
    static let cmuxReadOnlyCommands: [[String]] = {
        var commands: [[String]] = [
            ["tree"], ["identify"], ["current"], ["current-window"], ["current-workspace"],
            ["list-windows"], ["list-workspaces"], ["list-panes"], ["list-pane-surfaces"], ["list-panels"],
            ["list-status"], ["list-notifications"], ["list-log"], ["list-buffers"],
            ["read-screen"], ["read-selection"], ["capture-pane"], ["sidebar-state"], ["surface-health"],
            ["top"], ["memory"], ["version"], ["ping"], ["capabilities"], ["socket-status"], ["browser-status"],
            ["help"], ["docs"], ["guide"],
            ["workspace", "list"], ["todo", "list"], ["auth", "status"],
            ["settings", "path"], ["settings", "docs"],
            ["config", "get"], ["config", "path"], ["config", "paths"], ["config", "docs"],
            ["config", "check"], ["config", "validate"],
            ["chief", "status"], ["chief", "read"], ["chief", "conversations"], ["chief", "home"],
            ["chief", "memory", "list"], ["chief", "memory", "path"],
            // A saved fact shows in the transcript as "Chief will remember · Undo"
            // and passes the secret filter and size cap, so it needs no card.
            ["chief", "memory", "add"],
        ]
        for vm in ["vm", "cloud"] {
            commands += [
                [vm, "ls"], [vm, "status"], [vm, "tree"], [vm, "stats"], [vm, "self"], [vm, "wait"],
                [vm, "terminal", "read"], [vm, "terminal", "wait"], [vm, "terminal", "wait-exit"],
                [vm, "terminal", "output"],
            ]
        }
        return commands
    }()

    private static let plainReadOnlyPrograms: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "which", "jq", "grep", "cut", "tr", "column",
        "rg", "sort", "uniq", "awk", "sed",
    ]

    /// Whether one simple command (quotes removed) runs without asking.
    static func autoAllowsSimpleCommand(
        _ words: [String],
        home: String = NSHomeDirectory(),
        inputFromPipe: Bool = false
    ) -> Bool {
        // A bare program name only: `/tmp/x/cmux` is not the cmux CLI.
        guard let program = words.first else { return false }
        let args = Array(words.dropFirst())
        switch program {
        case "cmux":
            return autoAllowsCmux(args)
        case _ where plainReadOnlyPrograms.contains(program):
            return autoAllowsPlainReadOnly(program, args: args, home: home, inputFromPipe: inputFromPipe)
        case "date":
            return !args.contains { $0 == "-s" || $0.hasPrefix("--set") }
        case "git":
            return autoAllowsGit(args)
        case "gh":
            return autoAllowsGitHub(args)
        default:
            return false
        }
    }

    /// Plain readers must still refuse credential paths. A shell command such
    /// as `cat ~/.aws/credentials` must receive the same protection as Claude's
    /// structured `Read` tool. Every non-option operand is resolved relative to
    /// Chief's home, then checked after symlink resolution. Treating patterns
    /// and scripts as operands is intentionally conservative: a false approval
    /// is worse than asking for a harmless filter.
    private static func autoAllowsPlainReadOnly(
        _ program: String,
        args: [String],
        home: String,
        inputFromPipe: Bool
    ) -> Bool {
        switch program {
        case "sort":
            guard autoAllowsSort(args) else { return false }
        case "uniq":
            // `uniq in out` writes `out`.
            guard args.filter({ !$0.hasPrefix("-") }).count <= 1 else { return false }
        case "awk":
            guard autoAllowsAwk(args) else { return false }
        case "sed":
            guard autoAllowsSed(args) else { return false }
        default:
            break
        }

        let paths = ChiefSensitivePaths(home: home)
        var afterDoubleDash = false
        let pathArguments = args.reduce(into: [String]()) { paths, arg in
            if afterDoubleDash {
                paths.append(arg)
            } else if arg == "--" {
                afterDoubleDash = true
            } else if !arg.hasPrefix("-") {
                paths.append(arg)
            }
        }
        let checkedPaths: [String]
        let usesSearchRoot = ["ls", "rg", "grep"].contains(program)
        if usesSearchRoot {
            guard let operands = searchOperands(program, args: args, inputFromPipe: inputFromPipe) else { return false }
            checkedPaths = operands
        } else {
            checkedPaths = pathArguments
        }
        return !checkedPaths.contains { path in
            let absolute = path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
                ? path
                : URL(fileURLWithPath: home, isDirectory: true)
                    .appendingPathComponent(path, isDirectory: false).path
            // Directory readers/searchers must use the stricter root policy;
            // listing or recursively scanning `~` exposes credential stores
            // even when the directory itself is not a secret file.
            return usesSearchRoot ? !paths.allowsSearch(absolute) : !paths.allowsRead(absolute)
        }
    }

    /// Parse only the search flags whose operand behavior we model. Unknown
    /// flags (including pattern files, pre-processors and symlink following)
    /// ask rather than hiding a file access in an option's value.
    private static func searchOperands(_ program: String, args: [String], inputFromPipe: Bool) -> [String]? {
        let isListing = program == "ls"
        let shortFlags = isListing ? "1aAbBcCdFfGghiklmnopqRrSstTuUwWx" : "iInNwFxvcqsoHhZUPaSlLrR"
        let longFlags: Set<String> = isListing
            ? ["--all", "--almost-all", "--directory", "--human-readable", "--recursive", "--reverse"]
            : ["--ignore-case", "--case-sensitive", "--smart-case", "--line-number", "--no-line-number",
               "--word-regexp", "--line-regexp", "--fixed-strings", "--invert-match", "--count",
               "--files-with-matches", "--files-without-match", "--only-matching", "--quiet",
               "--with-filename", "--no-filename", "--no-heading", "--heading", "--text",
               "--hidden", "--no-ignore", "--no-ignore-vcs", "--no-config", "--null", "--null-data",
               "--recursive", "--files"]
        var operands: [String] = []
        var hasPattern = false
        var listsFiles = isListing
        var recursive = false
        var onlyOperands = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if onlyOperands || arg == "-" || !arg.hasPrefix("-") {
                operands.append(arg)
                continue
            }
            if arg == "--" { onlyOperands = true; continue }
            if !isListing, arg == "-e" || arg == "--regexp" {
                guard index < args.count else { return nil }
                index += 1
                hasPattern = true
                continue
            }
            if !isListing, arg.hasPrefix("--regexp=") { hasPattern = true; continue }
            if arg.hasPrefix("--") {
                guard longFlags.contains(arg) else { return nil }
                if arg == "--files" {
                    guard program == "rg" else { return nil }
                    listsFiles = true
                }
                if arg == "--recursive" { recursive = true }
                continue
            }
            var flags = arg.dropFirst()
            while let flag = flags.first {
                flags = flags.dropFirst()
                if !isListing, flag == "e" {
                    if flags.isEmpty {
                        guard index < args.count else { return nil }
                        index += 1
                    }
                    hasPattern = true
                    break
                }
                guard shortFlags.contains(flag) else { return nil }
                // ripgrep -L/-R follow symlinks; grep -R dereferences them.
                if (program == "rg" && (flag == "L" || flag == "R"))
                    || (program == "grep" && flag == "R") { return nil }
                if !isListing, flag == "r" || flag == "R" { recursive = true }
            }
        }
        // `grep` and `rg` consume their first positional operand as the
        // pattern unless `-e/--regexp` supplied it. `-l` changes the output,
        // not that positional grammar. `rg --files` is the one mode with no
        // pattern at all.
        if !isListing && !listsFiles && !hasPattern {
            guard !operands.isEmpty else { return nil }
            operands.removeFirst()
        }
        if operands.isEmpty && (isListing || listsFiles || recursive || !inputFromPipe) {
            // These forms search the current directory, which is Chief home.
            return nil
        }
        return operands
    }

    /// A read-only `cmux` command (``cmuxReadOnlyCommands``) with no word that asks.
    private static func autoAllowsCmux(_ args: [String]) -> Bool {
        if args.starts(with: ["workspace", "create"]) { return autoAllowsWorkspaceCreate(Array(args.dropFirst(2))) }
        guard let command = cmuxReadOnlyCommands.first(where: { args.starts(with: $0) }) else { return false }
        return !args.dropFirst(command.count).contains(where: cmuxWordAsks)
    }

    /// `cmux workspace create` that only names, describes and places a workspace in the
    /// background: no `--command` or `--layout` (they run commands), no `--focus true`.
    private static func autoAllowsWorkspaceCreate(_ args: [String]) -> Bool {
        let valueFlags: Set<String> = [
            "--name", "--description", "--cwd", "--window", "--group", "--group-placement", "--group-reference", "--id-format",
        ]
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--json" || arg == "--no-focus" { continue }
            if arg == "--focus" {
                guard index < args.count, args[index] == "false" else { return false }
                index += 1
                continue
            }
            if arg == "--focus=false" { continue }
            let key = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            guard valueFlags.contains(key) else { return false }
            if !arg.contains("=") {
                // A value that looks like a flag could be parsed as one (`--name --command x`).
                guard index < args.count, !args[index].hasPrefix("-") else { return false }
                index += 1
            }
        }
        return !args.contains(where: cmuxWordAsks)
    }

    /// `sort` with only ordering flags: GNU sort takes any unambiguous
    /// abbreviation of a long option (`--out=` is `--output=`), so nothing
    /// outside this list passes, `-o`, `-T` and `--compress-program` included.
    private static func autoAllowsSort(_ args: [String]) -> Bool {
        let longFlags: Set<String> = [
            "--numeric-sort", "--reverse", "--unique", "--ignore-case", "--ignore-leading-blanks",
            "--human-numeric-sort", "--version-sort", "--general-numeric-sort", "--month-sort", "--stable",
            "--dictionary-order", "--ignore-nonprinting", "--zero-terminated", "--check",
        ]
        let shortFlags = "nrufbhVgMsdizc"
        var index = 0
        var onlyFiles = false
        while index < args.count {
            let arg = args[index]
            index += 1
            if onlyFiles || arg == "-" || !arg.hasPrefix("-") { continue }
            if arg == "--" { onlyFiles = true; continue }
            if arg.hasPrefix("--") {
                if longFlags.contains(arg) || arg.hasPrefix("--key=") || arg.hasPrefix("--field-separator=") { continue }
                if arg == "--key" || arg == "--field-separator" { index += 1; continue }
                return false
            }
            var flags = arg.dropFirst()
            while let flag = flags.first {
                flags = flags.dropFirst()
                if flag == "k" || flag == "t" {
                    // The rest of the word is the value, else the next word.
                    if flags.isEmpty { index += 1 }
                    break
                }
                guard shortFlags.contains(flag) else { return false }
            }
        }
        return true
    }

    private static func autoAllowsAwk(_ args: [String]) -> Bool {
        let blockedFlags = ["-f", "--file", "-i", "--include", "-l", "--load", "-E", "--exec"]
        let blockedText = ["system", "|", ">", "getline", "@"]
        return !args.contains { arg in
            blockedFlags.contains { arg.hasPrefix($0) }
                || blockedText.contains { arg.contains($0) }
        }
    }

    private static let sedAddress = #"(?:\d+(?:~\d+)?|\$|/(?:\\.|[^/\\])*/I?)"#
    private static let sedCommand = try! NSRegularExpression(pattern:
        #"^\s*(?:"# + sedAddress + #"(?:\s*,\s*(?:"# + sedAddress + #"|[+~]\d+))?\s*!?\s*)?"#
        + #"(?:[pP=lqQdn]|s/(?:\\.|[^/\\])*/(?:\\.|[^/\\])*/[gpiI0-9]*)?\s*$"#)

    /// `sed -n` whose scripts only print: no `-i`, `-f`, `w`, `e` or `r`.
    private static func autoAllowsSed(_ args: [String]) -> Bool {
        var quiet = false
        var scripts: [String] = []
        var positionals: [String] = []
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "-e" || arg == "--expression" {
                guard let script = iterator.next() else { return false }
                scripts.append(script)
            } else if arg.hasPrefix("--expression=") {
                scripts.append(String(arg.dropFirst("--expression=".count)))
            } else if ["--quiet", "--silent"].contains(arg) {
                quiet = true
            } else if ["--regexp-extended", "--separate", "--unbuffered", "--null-data", "--posix", "--"].contains(arg) {
                continue
            } else if arg.hasPrefix("-"), arg.count > 1, !arg.hasPrefix("--") {
                let flags = arg.dropFirst()
                guard flags.allSatisfy({ "nErsuz".contains($0) }) else { return false }
                if flags.contains("n") { quiet = true }
            } else if arg.hasPrefix("--") {
                return false
            } else {
                positionals.append(arg)
            }
        }
        if scripts.isEmpty {
            guard !positionals.isEmpty else { return false }
            scripts.append(positionals.removeFirst())
        }
        guard quiet else { return false }
        return scripts.allSatisfy { script in
            script.split(whereSeparator: { $0 == ";" || $0 == "\n" }).allSatisfy { part in
                let text = String(part)
                return sedCommand.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
    }

    private static let readOnlyGit: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog",
        "merge-base", "show-ref", "branch", "tag", "remote", "worktree", "stash", "config",
    ]

    private static func autoAllowsGit(_ args: [String]) -> Bool {
        var rest = args[...]
        // `git -C <dir>` and `--no-pager` are the only global options allowed;
        // `-c key=value` could set a pager or hook.
        while let first = rest.first, first.hasPrefix("-") {
            if first == "-C", rest.count > 1 {
                rest = rest.dropFirst(2)
            } else if first == "--no-pager" {
                rest = rest.dropFirst()
            } else {
                return false
            }
        }
        guard let sub = rest.first, readOnlyGit.contains(sub) else { return false }
        let subArgs = Array(rest.dropFirst())
        // git takes unambiguous abbreviations of long options (`--outp=` is `--output=`).
        if subArgs.contains(where: { arg in
            let key = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            return key.hasPrefix("--output") || (key.count > 3 && "--output".hasPrefix(key))
        }) { return false }
        let positionals = subArgs.filter { !$0.hasPrefix("-") }
        switch sub {
        case "branch":
            return autoAllowsGitBranch(subArgs)
        case "tag":
            let creating = ["-d", "--delete", "-a", "--annotate", "-s", "--sign", "-u", "-f", "--force", "-m", "-F", "-e"]
            if subArgs.contains(where: { creating.contains($0) }) { return false }
            return positionals.isEmpty || subArgs.contains { $0 == "-l" || $0 == "--list" }
        case "remote":
            return positionals.isEmpty || ["get-url", "show"].contains(positionals[0])
        case "worktree":
            return positionals.first == "list"
        case "stash":
            return ["list", "show"].contains(positionals.first ?? "")
        case "config":
            let reads = ["--get", "--get-all", "--get-regexp", "--list", "-l"]
            return subArgs.contains { reads.contains($0) }
                && !subArgs.contains { ["--add", "--unset", "--unset-all", "--replace-all", "--edit", "-e",
                                         "--rename-section", "--remove-section"].contains($0) }
        default:
            return true
        }
    }

    /// `git branch` in listing mode only.
    private static func autoAllowsGitBranch(_ args: [String]) -> Bool {
        let listingFlags: Set<String> = [
            "--list", "--all", "--remotes", "--verbose", "--show-current", "--contains", "--no-contains",
            "--merged", "--no-merged", "--points-at", "--column", "--no-column", "--color", "--no-color",
            "--abbrev", "--no-abbrev", "--ignore-case", "--omit-empty",
        ]
        let listingValues = ["--sort=", "--format=", "--color=", "--contains=", "--no-contains=", "--merged=",
                             "--no-merged=", "--points-at=", "--abbrev=", "--column="]
        let listMode: Set<String> = ["--list", "-l", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"]
        var sawListMode = false
        var sawPositional = false
        for arg in args {
            if arg.hasPrefix("--") {
                guard listingFlags.contains(arg) || listingValues.contains(where: { arg.hasPrefix($0) }) else { return false }
            } else if arg.hasPrefix("-"), arg.count > 1 {
                guard arg.dropFirst().allSatisfy({ "avrl".contains($0) }) else { return false }
            } else {
                sawPositional = true
            }
            let shortList = arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.contains("l")
            let valueList = ["--contains=", "--no-contains=", "--merged=", "--no-merged=", "--points-at="]
                .contains { arg.hasPrefix($0) }
            if listMode.contains(arg) || shortList || valueList { sawListMode = true }
        }
        // A bare `git branch <name>` creates a branch.
        return !sawPositional || sawListMode
    }

    private static let readOnlyGitHub: [String: Set<String>] = [
        "issue": ["view", "list", "status"],
        "pr": ["view", "list", "diff", "checks", "status"],
        "run": ["view", "list"],
        "workflow": ["view", "list"],
        "release": ["view", "list"],
        "repo": ["view"],
        "search": ["issues", "prs", "repos", "code", "commits"],
    ]

    private static func autoAllowsGitHub(_ args: [String]) -> Bool {
        guard args.count >= 2, let allowed = readOnlyGitHub[args[0]] else { return false }
        return allowed.contains(args[1])
    }

    /// `argv` as one shell line, quoting each argument that needs it, so a
    /// legacy Codex `["/bin/zsh", "-lc", "a | b"]` unwraps to `a | b`.
    static func shellJoin(_ argv: [String]) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=,@%+")
        return argv.map { arg in
            if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ plain.contains($0) }) { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
        }.joined(separator: " ")
    }

    /// The inner command of `bash -lc '…'`, `zsh -c "…"` and the like, or
    /// `command` itself.
    static func unwrapShell(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let shells = ["sh", "bash", "zsh"]
        for shell in shells {
            for prefix in ["/bin/\(shell) ", "/usr/bin/\(shell) ", "\(shell) "] {
                for flag in ["-lc ", "-c "] where trimmed.hasPrefix(prefix + flag) {
                    let rest = String(trimmed.dropFirst(prefix.count + flag.count))
                    // The script must be exactly one shell word; the inner
                    // line is checked again on its own.
                    if let stages = ChiefShellLexer.stages(of: rest), stages.count == 1, stages[0].count == 1 {
                        return stages[0][0].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return trimmed
                }
            }
        }
        return trimmed
    }

    /// A short title for a Claude Code tool call, such as the `description`
    /// of a `Bash` call or `Read Sources/App.swift`.
    ///
    /// - Parameters:
    ///   - tool: The tool name.
    ///   - input: The tool's input.
    static func claudeTitle(_ tool: String, input: ChiefJSON) -> String {
        let text: String
        switch tool {
        case "Bash":
            text = nonEmpty(input["description"]?.string) ?? input["command"]?.string ?? "Run a command"
        case "Read":
            text = "Read " + (input["file_path"]?.string ?? "a file")
        case "Write":
            text = "Write " + (input["file_path"]?.string ?? "a file")
        case "Edit", "MultiEdit":
            text = "Edit " + (input["file_path"]?.string ?? "a file")
        case "Glob", "Grep":
            text = "Search " + (input["pattern"]?.string ?? "files")
        case "WebFetch":
            text = "Fetch " + (input["url"]?.string ?? "a page")
        case "WebSearch":
            text = "Search the web: " + (input["query"]?.string ?? "")
        case "ToolSearch":
            text = "Find tools"
        default:
            // MCP tools are `mcp__server__tool`; the last part reads best.
            let parts = tool.components(separatedBy: "__")
            text = parts.count >= 3 ? parts.dropFirst(2).joined(separator: "__") : tool
        }
        return truncate(text.replacingOccurrences(of: "\n", with: " "), to: 80)
    }

    /// The full input of a tool call for its work card: the command for a
    /// shell call, compact JSON otherwise.
    static func claudeDetail(_ tool: String, input: ChiefJSON) -> String? {
        if tool == "Bash", let command = input["command"]?.string { return command }
        if case .object(let members) = input, members.isEmpty { return nil }
        return truncate(input.compactText, to: 4000)
    }

    /// The approval prompt for a Claude Code permission request.
    static func claudePrompt(_ tool: String, input: ChiefJSON) -> String {
        if tool == "Bash", let command = input["command"]?.string {
            return "Run `\(truncate(command, to: 300))`?"
        }
        return "Allow \(claudeTitle(tool, input: input))?"
    }

    /// The first few lines of a tool result, for a finished work card.
    ///
    /// - Parameter text: The tool's output.
    /// - Returns: Up to 3 lines and 240 characters, nil for empty output.
    static func preview(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(3)
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : truncate(joined, to: 240)
    }

    /// `text` cut to `limit` characters with an ellipsis.
    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}

/// Where credentials live, so ``ChiefToolPolicy`` asks before Claude Code's
/// `Read`, `Glob` or `Grep` touches them.
///
/// Sensitive: anything under `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`,
/// `~/.config/gcloud`, `~/.azure`, `~/.docker`, `~/.kube`, `~/Library/Keychains`,
/// `/Library/Keychains`, `~/Library/Cookies`, `~/Library/Safari` and browser
/// profiles under `~/Library/Application Support`; a name under `~/.cmux`
/// starting with `auth`; and, anywhere, `.netrc`, `.git-credentials`,
/// `.npmrc`, `.pypirc`, `.pgpass`, `.env` and `.env.*`, `*.pem`, `*.key`,
/// `*.p12`, `*.pfx`, keychain files, SSH private keys (`id_rsa`, …) and
/// browser `Cookies`/`Login Data` databases.
///
/// Paths are compared lowercased (the Mac's file system ignores case) after
/// expanding `~`, removing `.` and `..`, and resolving symlinks. A search
/// root must also not contain a sensitive folder: the home folder, its
/// ancestors, `~/Library`, `~/.config` or `~/.cmux` ask. A search below an
/// allowed root can still meet a project's own key file; this blocks the
/// well-known stores, not every secret on disk.
struct ChiefSensitivePaths {
    private let home: String
    private let homePath: String
    private let roots: [String]
    private let searchCovers: [String]

    init(home: String) {
        homePath = home
        let home = (Self.resolve(home, home: home) ?? home).lowercased()
        self.home = home
        let underHome = [
            ".ssh", ".aws", ".gnupg", ".config/gh", ".config/gcloud", ".azure", ".docker", ".kube",
            "library/keychains", "library/cookies", "library/safari", "library/containers/com.apple.safari",
            "library/application support/google/chrome", "library/application support/bravesoftware",
            "library/application support/firefox", "library/application support/microsoft edge",
            "library/application support/arc", "library/application support/chromium",
            "library/application support/vivaldi", "library/application support/com.operasoftware.opera",
        ]
        let roots = underHome.map { home + "/" + $0 } + ["/library/keychains"]
        self.roots = roots
        // Folders a search must not cover: each sensitive root, plus `~/.cmux` (auth files inside).
        searchCovers = roots + [home + "/.cmux"]
    }

    /// Whether `Read` of `path` runs without asking.
    func allowsRead(_ path: String) -> Bool {
        guard let resolved = resolved(path) else { return false }
        return !isSensitive(resolved)
    }

    /// Whether a `Glob` or `Grep` rooted at `path` runs without asking.
    func allowsSearch(_ path: String) -> Bool {
        guard let resolved = resolved(path), !isSensitive(resolved) else { return false }
        // `/`, `/Users`, the home folder itself, or a folder holding a credential store.
        if resolved == "/" || home.hasPrefix(resolved + "/") || resolved == home { return false }
        return !searchCovers.contains { $0.hasPrefix(resolved + "/") || $0 == resolved }
    }

    /// Whether a glob filter (`**/.env`, `*.pem`, `.ssh/*`) names a credential file or folder.
    func patternNamesSecrets(_ pattern: String) -> Bool {
        let lower = pattern.lowercased()
        let markers = [
            ".ssh", ".aws", ".gnupg", ".netrc", ".docker", ".kube", ".env", ".git-credentials", ".npmrc",
            ".pypirc", ".pgpass", "keychain", "cookies", "login data", ".pem", ".key", ".p12", ".pfx",
            "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials", "auth", "secret", "token",
        ]
        return markers.contains { lower.contains($0) }
    }

    private func resolved(_ path: String) -> String? {
        Self.resolve(path, home: homePath).map { $0.lowercased() }
    }

    /// `path` absolute, with `~` expanded to `home`, `.`/`..` removed and symlinks resolved; nil
    /// when relative (`~user` included).
    private static func resolve(_ path: String, home: String) -> String? {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        guard expanded.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    private func isSensitive(_ path: String) -> Bool {
        if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        let cmux = home + "/.cmux/"
        if path.hasPrefix(cmux), path.dropFirst(cmux.count).split(separator: "/").contains(where: { $0.hasPrefix("auth") }) {
            return true
        }
        let names: Set<String> = [
            ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".pgpass", ".env", "cookies", "cookies-journal",
            "login data", "login data-journal", "web data", "key4.db", "logins.json", "cookies.sqlite", "cookies.binarycookies",
        ]
        let suffixes = [".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".ppk"]
        let keyNames = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
        return path.split(separator: "/").contains { part in
            let name = String(part)
            return names.contains(name) || name.hasPrefix(".env.") || suffixes.contains { name.hasSuffix($0) }
                || keyNames.contains { name.hasPrefix($0) }
        }
    }
}
