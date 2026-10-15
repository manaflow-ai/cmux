import CmuxFoundation
import Darwin
import Foundation

/// `cmux vm clone <repo>` (alias `cmux vm repo clone`): one step from a repository to a
/// checkout on a cloud machine, opened in the app — the composition an agent otherwise
/// types as `vm route` → `vm secrets sync` → `vm exec -- git clone …` →
/// `vm workspace new` → `vm terminal send cd …` → `vm agent --remote-workspace …`.
///
/// Every step goes through the socket methods those verbs use (`selectVMForRun`,
/// `vm.secrets_sync`, `vm.exec`, `vm.workspace_new`, `vm.terminal_write`,
/// `surface.new_terminal`), so the composition and the verbs cannot disagree. The clone
/// runs on the machine: a large repository never transits the Mac, and the credential
/// is the machine's own (`GH_TOKEN` from Cloud Secrets, read by git's credential helper
/// at use time), never part of the command.
///
/// Idempotent: a second run against a directory that already holds the same repository
/// fetches and checks the branch out instead of cloning, and the workspace is
/// get-or-create by the repository's name.
extension CMUXCLI {
    static var vmCloneUsage: String {
        """
        Usage: cmux vm clone <repo> [--machine <id> | --new] [--size <4g|8g|16g|24g|32g|64g|MB>] [--branch <b>] [--dir <remote-dir>] [--agent <claude|codex|opencode|pi> [-- <prompt>]] [--no-open] [--focus|--no-focus] [--dry-run] [--json]
               cmux vm repo clone <repo> [same options]

        Clone a repository on a cloud machine and open it, in one command:
          1. machine    pick the machine like `vm agent` (sticky per repository, then an
                        idle pool machine, then a fresh one) unless --machine / --new
          2. secrets    sync Cloud Secrets to it, so GH_TOKEN and the project's keys land
                        before git runs (private GitHub repositories need GH_TOKEN)
          3. clone      `git clone` on the machine into work/<repo>; when that directory is
                        already a checkout of the same repository, fetch and check the
                        branch out instead
          4. workspace  get-or-create the machine workspace named after the repository with
                        a terminal in the checkout, opened here unless --no-open; --agent
                        also starts that agent in the checkout

        <repo>:
          https://github.com/<owner>/<repo>               a GitHub repository
          https://github.com/<owner>/<repo>/tree/<branch>  a branch of it
          git@github.com:<owner>/<repo>.git               (cloned over https so GH_TOKEN works)
          <owner>/<repo>                                  shorthand for github.com
          https://<host>/<path>.git                       any https git URL
          .                                               this folder's origin remote and the
                                                          branch it tracks there (uncommitted or
                                                          unpushed work stays here; use `vm push`)

        Options:
          --machine <id>   Skip routing and use this machine.
          --new            Force a fresh pool machine.
          --size <4g|8g|16g|24g|32g|64g|MB>
                           Memory preset for a machine this call creates
                           (4g to 16g on Pro; 24g, 32g, and 64g need cmux Max).
          --branch <b>     Check this branch out (overrides a /tree/<branch> URL).
          --dir <path>     Where the checkout lives on the machine, relative to the home
                           directory unless absolute (default: work/<repo>).
          --agent <name>   Start claude | codex | opencode | pi in the checkout. Words after
                           `--` are its prompt (the agent's one-shot form, like `vm agent`);
                           without them the agent starts interactively.
          --no-open        Do everything on the machine; open nothing here.
          --focus, --no-focus
                           Focus the opened workspace, or open it in the background.
                           \(openFocusDefaultHelp)
          --dry-run        Print the plan (clone URL, branch, project, directory) without
                           touching the machine.
          --json           {machine, created, reason, repo: {url, name, owner, branch, project},
                            dir, result, workspace_id, local_workspace_id, terminal_id,
                            agent_terminal_id, open, timings}

        Private repositories: add a GitHub token once with `cmux vm secrets import --gh`.

        Examples:
          cmux vm clone manaflow-ai/cmux
          cmux vm clone https://github.com/vercel/next.js/tree/canary --new --size 16g
          cmux vm clone . --agent claude -- "run the test suite and fix failures"
          cmux vm clone git@github.com:acme/api.git --machine vivid-newt --no-open --json
        """
    }

    // MARK: - Repository spec (pure)

    /// A parsed `<repo>` argument: what the machine clones, what the checkout and
    /// workspace are named, and the Cloud Secrets project key it maps to.
    struct VMCloneRepoSpec: Equatable {
        /// The URL handed to `git clone`. GitHub repositories always clone over https so
        /// the machine's GH_TOKEN credential helper applies.
        let cloneURL: String
        /// The repository's own name (the last path component without `.git`).
        let name: String
        /// The owner or group path, when the URL has one.
        let owner: String?
        /// The branch named by the URL (`/tree/<branch>`) or `--branch`; nil means the
        /// remote's default branch.
        let branch: String?
        /// The normalized project key: lowercased `host/path`, no `.git`
        /// (`github.com/owner/repo`), the same shape Cloud Secrets uses.
        let projectKey: String
    }

    /// Parses a repository argument (everything except `.`, which needs the local git
    /// state and is resolved by ``resolveVMCloneDotRepo(directory:branchOverride:)``).
    /// `branchOverride` (from `--branch`) wins over a branch in the URL.
    static func parseVMCloneRepoSpec(_ raw: String, branchOverride: String? = nil) throws -> VMCloneRepoSpec {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CLIError(message: Self.vmCloneUsage)
        }
        if let override = branchOverride {
            guard isValidVMCloneBranch(override) else {
                throw CLIError(message: String(
                    format: String(localized: "cli.vm.clone.invalidBranch", defaultValue: "vm clone: '%@' is not a valid branch name."),
                    override
                ))
            }
        }
        let unrecognized = CLIError(message: String(
            format: String(
                localized: "cli.vm.clone.unrecognizedRepo",
                defaultValue: "vm clone: '%@' is not a repository. Use https://github.com/<owner>/<repo>, <owner>/<repo>, git@<host>:<path>.git, an https git URL, or `.`."
            ),
            text
        ))
        let credentialsError = CLIError(message: String(
            localized: "cli.vm.clone.credentialsInURL",
            defaultValue: "vm clone: the repository URL carries credentials. Remove them from the URL and add the token to Cloud Secrets instead: `cmux vm secrets import --gh`."
        ))

        var host: String
        let segments: [String]
        var urlForGeneric: String
        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git"].contains(scheme),
                  let components = URLComponents(string: text),
                  let rawHost = components.host, !rawHost.isEmpty else {
                throw unrecognized
            }
            // A password is a credential anywhere; a user name is one too on http(s)
            // (`https://<token>@github.com/…`). `ssh://git@host/…` is just the login.
            if components.password != nil { throw credentialsError }
            if components.user != nil, scheme == "https" || scheme == "http" { throw credentialsError }
            guard components.query == nil, components.fragment == nil else { throw unrecognized }
            host = rawHost.lowercased()
            segments = components.path.split(separator: "/").map(String.init)
            urlForGeneric = text
            while urlForGeneric.hasSuffix("/") { urlForGeneric.removeLast() }
        } else if let scp = parseVMCloneSCPLike(text) {
            host = scp.host
            segments = scp.path.split(separator: "/").map(String.init)
            urlForGeneric = text
        } else if isVMCloneShorthand(text) {
            host = "github.com"
            segments = text.split(separator: "/").map(String.init)
            urlForGeneric = ""
        } else {
            throw unrecognized
        }
        if host == "www.github.com" { host = "github.com" }

        if host == "github.com" {
            guard segments.count >= 2 else { throw unrecognized }
            let owner = segments[0]
            let name = stripVMCloneGitSuffix(segments[1])
            guard isValidVMClonePathComponent(owner), isValidVMClonePathComponent(name) else { throw unrecognized }
            var urlBranch: String?
            if segments.count >= 4, segments[2] == "tree" {
                let joined = segments[3...].joined(separator: "/")
                urlBranch = joined.removingPercentEncoding ?? joined
            }
            let branch = branchOverride ?? urlBranch
            if let branch, !isValidVMCloneBranch(branch) {
                throw CLIError(message: String(
                    format: String(localized: "cli.vm.clone.invalidBranch", defaultValue: "vm clone: '%@' is not a valid branch name."),
                    branch
                ))
            }
            return VMCloneRepoSpec(
                cloneURL: "https://github.com/\(owner)/\(name).git",
                name: name,
                owner: owner,
                branch: branch,
                projectKey: "github.com/\(owner)/\(name)".lowercased()
            )
        }

        // Any other host: clone the URL exactly as given.
        guard let last = segments.last else { throw unrecognized }
        let name = stripVMCloneGitSuffix(last)
        guard isValidVMClonePathComponent(name) else { throw unrecognized }
        var keySegments = segments
        keySegments[keySegments.count - 1] = name
        guard keySegments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw unrecognized }
        let owner = segments.count > 1 ? segments.dropLast().joined(separator: "/") : nil
        return VMCloneRepoSpec(
            cloneURL: urlForGeneric,
            name: name,
            owner: owner,
            branch: branchOverride,
            projectKey: ([host] + keySegments).joined(separator: "/").lowercased()
        )
    }

    /// `[user@]host:path` (git's scp-like syntax). Requires a dotted host or a user so a
    /// bare `name:thing` is not mistaken for a remote.
    static func parseVMCloneSCPLike(_ text: String) -> (host: String, path: String)? {
        guard !text.contains("://"), let colon = text.firstIndex(of: ":") else { return nil }
        let authority = String(text[..<colon])
        var path = String(text[text.index(after: colon)...])
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, !authority.isEmpty, !authority.contains("/") else { return nil }
        var hostPart = authority
        var hasUser = false
        if let at = authority.lastIndex(of: "@") {
            let user = authority[..<at]
            hostPart = String(authority[authority.index(after: at)...])
            guard !user.isEmpty, !user.contains(":") else { return nil }
            hasUser = true
        }
        let hostAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !hostPart.isEmpty,
              hostPart.unicodeScalars.allSatisfy({ hostAllowed.contains($0) }),
              hasUser || hostPart.contains(".") else { return nil }
        return (hostPart.lowercased(), path)
    }

    /// `owner/repo` (optionally `.git`): exactly two GitHub-safe components.
    static func isVMCloneShorthand(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return false }
        return isValidVMClonePathComponent(parts[0]) && isValidVMClonePathComponent(stripVMCloneGitSuffix(parts[1]))
    }

    static func stripVMCloneGitSuffix(_ value: String) -> String {
        value.lowercased().hasSuffix(".git") ? String(value.dropLast(4)) : value
    }

    /// Letters, digits, `.`, `_`, `-`; not `.`/`..` and not starting with `.` or `-`
    /// (the name becomes a directory and a workspace name on the machine).
    static func isValidVMClonePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200, !value.hasPrefix("."), !value.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A conservative subset of `git check-ref-format --branch`.
    static func isValidVMCloneBranch(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255,
              !value.hasPrefix("-"), !value.hasPrefix("/"), !value.hasSuffix("/"),
              !value.hasSuffix("."), !value.hasSuffix(".lock"),
              !value.contains(".."), !value.contains("//"), !value.contains("@{"),
              value != "@" else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        return !value.unicodeScalars.contains { forbidden.contains($0) }
    }

    /// The checkout directory on the machine: `--dir` (a leading `~/` is the home) or
    /// `work/<name>`. Relative paths resolve against the machine user's home.
    static func vmCloneRemoteDirectory(name: String, dirOption: String?) throws -> String {
        guard var dir = dirOption?.trimmingCharacters(in: .whitespaces) else { return "work/\(name)" }
        if dir == "~" { dir = "" }
        if dir.hasPrefix("~/") { dir.removeFirst(2) }
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        let components = dir.split(separator: "/", omittingEmptySubsequences: true)
        guard !dir.isEmpty, dir != "/",
              !components.contains(where: { $0 == ".." || $0 == "." }),
              !dir.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.vm.clone.invalidDir",
                    defaultValue: "vm clone: --dir '%@' is not a usable directory. Name a folder under the home directory (e.g. work/app) or an absolute path."
                ),
                dirOption ?? ""
            ))
        }
        return dir
    }

    /// The directory as a shell word that resolves the same way in any shell the
    /// machine starts: absolute stays absolute, relative hangs off "$HOME".
    static func vmCloneShellDirectory(_ dir: String) -> String {
        dir.hasPrefix("/") ? dir.posixShellWord : "\"$HOME\"/" + dir.posixShellWord
    }

    /// The sed program that maps any remote URL spelling to the project key, applied on
    /// the machine to an existing checkout's origin so `git@github.com:O/R.git` and
    /// `https://github.com/o/r` are the same repository.
    static let vmCloneRemoteKeySed = #"s#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]*@##; s#^([^/:]+):[0-9]+/#\1/#; s#^([^/:]+):/*#\1/#; s#/+$##; s#\.git$##; s#^www\.github\.com/#github.com/#"#

    /// The one `vm.exec` command that clones or updates the checkout. No credential is
    /// in it: git asks the machine's credential helper, which reads GH_TOKEN at use
    /// time. Prompts are disabled so a missing credential fails fast instead of
    /// hanging the exec. Prints `cmux-clone=cloned|updated` on success, exits 3 when the
    /// directory holds something else.
    static func vmCloneScript(spec: VMCloneRepoSpec, dir: String) -> String {
        let d = dir.posixShellWord
        let u = spec.cloneURL.posixShellWord
        let k = spec.projectKey.posixShellWord
        var update = "git -C \"$d\" fetch --prune origin || exit $?; "
        var cloneFlags = ""
        if let branch = spec.branch {
            let b = branch.posixShellWord
            let tracking = "origin/\(branch)".posixShellWord
            update += "{ git -C \"$d\" checkout --quiet \(b) -- 2>/dev/null || git -C \"$d\" checkout --quiet -b \(b) --track \(tracking); } || exit $?; "
            cloneFlags = "--branch \(b) "
        }
        update += "git -C \"$d\" merge --ff-only --quiet 2>/dev/null || true; echo cmux-clone=updated; "
        let parts: [String] = [
            "cd \"$HOME\" || exit 1",
            "export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'",
            "d=\(d); u=\(u); k=\(k)",
            "if [ -d \"$d/.git\" ]; then "
                + "o=$(git -C \"$d\" remote get-url origin 2>/dev/null | sed -E \(vmCloneRemoteKeySed.posixShellWord) | tr 'A-Z' 'a-z'); "
                + "if [ \"$o\" != \"$k\" ]; then echo \"cmux-clone-conflict: a checkout of ${o:-another repository}\" >&2; exit 3; fi; "
                + update
                + "elif [ -e \"$d\" ] && [ -n \"$(ls -A \"$d\" 2>/dev/null)\" ]; then "
                + "echo 'cmux-clone-conflict: a folder that is not a git checkout' >&2; exit 3; "
                + "else mkdir -p \"$(dirname \"$d\")\" && git clone \(cloneFlags)-- \"$u\" \"$d\" || exit $?; echo cmux-clone=cloned; fi",
        ]
        return parts.joined(separator: "; ")
    }

    /// Whether git's stderr says the machine could not authenticate (or the repository
    /// is private and invisible without a token).
    static func vmCloneLooksLikeAuthFailure(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return [
            "authentication failed",
            "could not read username",
            "could not read password",
            "repository not found",
            "terminal prompts disabled",
            "invalid username or password",
            "permission denied (publickey)",
            "the requested url returned error: 403",
        ].contains { text.contains($0) }
    }

    /// The routing key for a repository: sticky per repository, so a second clone (or a
    /// re-run) lands on the machine that already holds the checkout.
    static func vmCloneRoutingDirectory(projectKey: String) -> String {
        "/cmux-vm-clone/\(projectKey)"
    }

    // MARK: - `.`: this folder's origin remote

    /// `.`: the origin remote of the folder's repository and the branch it tracks there.
    /// A branch with no upstream on origin falls back to the remote's default branch,
    /// with a note, because the machine can only clone what origin has.
    func resolveVMCloneDotRepo(directory: String, branchOverride: String?) throws -> VMCloneRepoSpec {
        func git(_ arguments: [String]) -> String? {
            let result = CLIProcessRunner.runProcess(
                executablePath: "/usr/bin/env",
                arguments: ["git", "-C", directory] + arguments,
                timeout: 30
            )
            guard !result.timedOut, result.status == 0 else { return nil }
            let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
        guard let origin = git(["remote", "get-url", "origin"]) else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.vm.clone.dotNoOrigin",
                    defaultValue: "vm clone: %@ is not a git checkout with an origin remote. Clone a URL instead, or copy the folder with `cmux vm push`."
                ),
                directory
            ))
        }
        var branch = branchOverride
        if branch == nil,
           let local = git(["rev-parse", "--abbrev-ref", "HEAD"]), local != "HEAD" {
            if let upstream = git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]),
               upstream.hasPrefix("origin/") {
                branch = String(upstream.dropFirst("origin/".count))
            } else {
                cliWriteStderr(String(
                    format: String(
                        localized: "cli.vm.clone.dotNoUpstream",
                        defaultValue: "Note: branch %1$@ is not on origin, so the machine clones the default branch. Push it first (git push -u origin %1$@) to clone it."
                    ),
                    local
                ) + "\n")
            }
        }
        return try Self.parseVMCloneRepoSpec(origin, branchOverride: branch)
    }

    // MARK: - Command

    func runVMRepoCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let verb = rest.first?.lowercased(), verb == "clone" else {
            if rest.contains("--help") || rest.contains("-h") || rest.isEmpty {
                print(Self.vmCloneUsage)
                return
            }
            throw CLIError(message: Self.vmCloneUsage)
        }
        try runVMCloneCommand(rest: Array(rest.dropFirst()), client: client, jsonOutput: jsonOutput)
    }

    func runVMCloneCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        var flags = rest
        var promptArgs: [String] = []
        if let separator = rest.firstIndex(of: "--") {
            flags = Array(rest[..<separator])
            promptArgs = Array(rest[(separator + 1)...])
        }
        if flags.contains("--help") || flags.contains("-h") {
            print(Self.vmCloneUsage)
            return
        }
        var repoArg: String?
        var machineOverride: String?
        var forceNew = false
        var sizeOption: String?
        var branchOption: String?
        var dirOption: String?
        var agent: String?
        var noOpen = false
        var focus: Bool?
        var dryRun = false
        var index = 0
        while index < flags.count {
            let arg = flags[index]
            func takeValue() throws -> String {
                guard index + 1 < flags.count else {
                    throw CLIError(message: "\(arg) requires a value\n\n\(Self.vmCloneUsage)")
                }
                index += 1
                return flags[index]
            }
            if let flag = try Self.openFocusFlag(in: flags, at: index, command: "vm clone") {
                focus = flag.focus
                index += flag.consumed
                continue
            }
            switch arg {
            case "--machine": machineOverride = try takeValue()
            case "--new": forceNew = true
            case "--size": sizeOption = try takeValue()
            case "--branch", "-b": branchOption = try takeValue()
            case "--dir": dirOption = try takeValue()
            case "--agent": agent = try takeValue().lowercased()
            case "--no-open": noOpen = true
            case "--dry-run": dryRun = true
            case "--json": break
            default:
                if arg.hasPrefix("-") {
                    throw CLIError(message: "vm clone: unknown flag '\(arg)'\n\n\(Self.vmCloneUsage)")
                }
                guard repoArg == nil else {
                    throw CLIError(message: "vm clone: unexpected argument '\(arg)'\n\n\(Self.vmCloneUsage)")
                }
                repoArg = arg
            }
            index += 1
        }
        guard let repoArg else {
            throw CLIError(message: Self.vmCloneUsage)
        }
        if machineOverride != nil, forceNew {
            throw CLIError(message: "vm clone: --machine and --new are exclusive\n\n\(Self.vmCloneUsage)")
        }
        if let agent, !Self.vmAgentNames.contains(agent) {
            throw CLIError(message: "vm clone: --agent must be one of \(Self.vmAgentNames.joined(separator: ", "))\n\n\(Self.vmCloneUsage)")
        }
        if agent == nil, !promptArgs.isEmpty {
            throw CLIError(message: "vm clone: a prompt after `--` needs --agent <name>\n\n\(Self.vmCloneUsage)")
        }
        var memoryMb: Int?
        if let sizeOption {
            guard let parsed = Self.parseCloudVMSize(sizeOption) else {
                throw CLIError(message: "vm clone: unknown size '\(sizeOption)'. Sizes: 4g, 8g, 16g on Pro (24g, 32g, and 64g need cmux Max), or memory in MB (at least 512).")
            }
            memoryMb = parsed
        }
        // The agent's argv is fixed before anything touches a machine: a bare prompt gets
        // the one-shot form (`vm agent`'s rule), no prompt starts it interactively.
        let agentArgv: [String]?
        if let agent, !promptArgs.isEmpty {
            guard let argv = Self.vmAgentArgv(agent: agent, args: promptArgs) else {
                throw CLIError(message: Self.vmCloneUsage)
            }
            agentArgv = argv
        } else {
            agentArgv = agent.map { [$0] }
        }

        let cwd = FileManager.default.currentDirectoryPath
        let spec: VMCloneRepoSpec
        let routingDirectory: String
        if repoArg == "." {
            spec = try resolveVMCloneDotRepo(directory: cwd, branchOverride: branchOption)
            // `.` binds this folder, so a later `vm agent` / `vm run` here lands on the
            // machine that now holds its checkout.
            routingDirectory = cwd
        } else {
            spec = try Self.parseVMCloneRepoSpec(repoArg, branchOverride: branchOption)
            routingDirectory = Self.vmCloneRoutingDirectory(projectKey: spec.projectKey)
        }
        let remoteDir = try Self.vmCloneRemoteDirectory(name: spec.name, dirOption: dirOption)
        let workspaceName = spec.name
        let open = !noOpen
        let focusValue = focus ?? Self.defaultFocusForUserOpen()

        func orNull(_ value: Any?) -> Any {
            value ?? NSNull()
        }
        func repoPayload() -> [String: Any] {
            var payload: [String: Any] = [:]
            payload["url"] = spec.cloneURL
            payload["name"] = spec.name
            payload["owner"] = orNull(spec.owner)
            payload["branch"] = orNull(spec.branch)
            payload["project"] = spec.projectKey
            return payload
        }

        if dryRun {
            if jsonOutput {
                var plan: [String: Any] = [:]
                plan["dry_run"] = true
                plan["repo"] = repoPayload()
                plan["dir"] = remoteDir
                plan["workspace_name"] = workspaceName
                plan["machine"] = orNull(machineOverride)
                plan["new"] = forceNew
                plan["agent"] = orNull(agent)
                plan["agent_command"] = orNull(agentArgv)
                plan["open"] = open
                print(jsonString(plan))
            } else {
                let machineText = machineOverride ?? (forceNew ? "a fresh pool machine" : "routed (sticky per repository, then the idle pool)")
                let branchText = spec.branch.map { " (branch \($0))" } ?? " (default branch)"
                print("plan: clone \(spec.cloneURL)\(branchText)")
                print("plan: project \(spec.projectKey)")
                print("plan: machine \(machineText), checkout \(remoteDir)")
                print("plan: workspace \(workspaceName) (get-or-create)\(open ? ", opened here" : ", not opened")")
                if let agentArgv {
                    print("plan: agent \(agentArgv.map { $0.posixShellWord }.joined(separator: " "))")
                }
            }
            return
        }

        var timings: [(key: String, label: String, seconds: Double)] = []
        func phase(_ key: String, _ label: String, _ started: Date, detail: String) {
            let seconds = Date().timeIntervalSince(started)
            timings.append((key, label, seconds))
            cliWriteStderr("[cmux vm clone] \(label) \(String(format: "%.1fs", seconds)) \u{2014} \(detail)\n")
        }

        // 1. Machine: `vm agent`'s router, keyed per repository.
        let machineLabel = String(localized: "cli.vm.clone.phase.machine", defaultValue: "Machine")
        let machineStarted = Date()
        let selection = try selectVMForRun(
            machineOverride: machineOverride,
            forceNew: forceNew,
            memoryMb: memoryMb,
            workDirectory: routingDirectory,
            client: client
        )
        Self.saveVMRunBinding(workKey: Self.vmRunWorkKey(forDirectory: routingDirectory), machine: selection.id)
        phase("machine", machineLabel, machineStarted, detail: "\(selection.id) (\(selection.reason))")
        let machine = selection.id

        // 2. Secrets: GH_TOKEN and the project's keys land before git runs. A Mac without
        // Cloud Secrets (older app) or a failed delivery still clones public repositories.
        let secretsLabel = String(localized: "cli.vm.clone.phase.secrets", defaultValue: "Secrets")
        let secretsStarted = Date()
        let secretsTip = String(
            localized: "cli.vm.clone.secretsTip",
            defaultValue: "Tip: add a GitHub token with `cmux vm secrets import --gh` to clone private repos."
        )
        let (secretsSynced, secretsDetail) = syncVMCloneSecrets(machine: machine, projectKey: spec.projectKey, client: client)
        phase("secrets", secretsLabel, secretsStarted, detail: secretsDetail)
        if !secretsSynced {
            cliWriteStderr(secretsTip + "\n")
        }

        // 3. Clone (or fetch + checkout) on the machine.
        let cloneLabel = String(localized: "cli.vm.clone.phase.clone", defaultValue: "Clone")
        let cloneStarted = Date()
        let cloneTimeoutMs = 15 * 60 * 1000
        let cloneResponse = try client.sendV2(
            method: "vm.exec",
            params: [
                "id": machine,
                "command": Self.vmCloneScript(spec: spec, dir: remoteDir),
                "timeout_ms": cloneTimeoutMs,
            ],
            responseTimeout: TimeInterval(cloneTimeoutMs / 1000 + 60)
        )
        let cloneStdout = (cloneResponse["stdout"] as? String) ?? ""
        let cloneStderr = ((cloneResponse["stderr"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cloneExit = (cloneResponse["exit_code"] as? Int) ?? -1
        if cloneExit != 0 {
            if cloneExit == 3, cloneStderr.contains("cmux-clone-conflict:") {
                let what = cloneStderr
                    .components(separatedBy: "cmux-clone-conflict:").last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.vm.clone.conflict",
                        defaultValue: "vm clone: %1$@ on %2$@ already holds %3$@. Pass --dir <path> to clone somewhere else."
                    ),
                    remoteDir, machine, what
                ))
            }
            if Self.vmCloneLooksLikeAuthFailure(cloneStderr) {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.vm.clone.authFailed",
                        defaultValue: "vm clone: %1$@ could not read %2$@ \u{2014} the repository is private or the machine has no access to it. Add a GitHub token with `cmux vm secrets import --gh`, then run this again."
                    ),
                    machine, spec.cloneURL
                ))
            }
            let detail = cloneStderr.isEmpty ? "" : "\n\(cloneStderr)"
            throw CLIError(message: String(
                format: String(
                    localized: "cli.vm.clone.failed",
                    defaultValue: "vm clone: git failed on %1$@ (exit %2$d)%3$@"
                ),
                machine, cloneExit, detail
            ))
        }
        let updated = cloneStdout.contains("cmux-clone=updated")
        let result = updated ? "updated" : "cloned"
        phase(
            "clone",
            cloneLabel,
            cloneStarted,
            detail: String(
                format: updated
                    ? String(localized: "cli.vm.clone.updated", defaultValue: "updated %1$@ in %2$@")
                    : String(localized: "cli.vm.clone.cloned", defaultValue: "cloned %1$@ into %2$@"),
                spec.projectKey, remoteDir
            )
        )

        // 4. Workspace: get-or-create by the repository's name, a terminal in the
        // checkout, opened here unless --no-open.
        let workspaceLabel = String(localized: "cli.vm.clone.phase.workspace", defaultValue: "Workspace")
        let workspaceStarted = Date()
        var workspaceParams: [String: Any] = [
            "id": machine,
            "name": workspaceName,
            "reuse": true,
            "focus": focusValue,
        ]
        if !open { workspaceParams["open"] = false }
        let workspaceResponse = try client.sendV2(method: "vm.workspace_new", params: workspaceParams, responseTimeout: 240)
        let remoteWorkspace = (workspaceResponse["remote_workspace_id"] as? String) ?? "?"
        let existingWorkspace = (workspaceResponse["existing"] as? Bool) ?? false
        let starterTerminal = (workspaceResponse["terminal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let localWorkspace = (workspaceResponse["workspace_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // A fresh workspace's starter shell begins in the home directory; move it into the
        // checkout. An existing workspace keeps whatever its terminals are doing.
        if !existingWorkspace, let starterTerminal {
            _ = try client.sendV2(
                method: "vm.terminal_write",
                params: [
                    "id": machine,
                    "terminal_id": starterTerminal,
                    "text": "cd \(Self.vmCloneShellDirectory(remoteDir))",
                    "keys": ["enter"],
                ],
                responseTimeout: 120
            )
        }
        phase(
            "workspace",
            workspaceLabel,
            workspaceStarted,
            detail: "\(workspaceName) \(remoteWorkspace)\(existingWorkspace ? " (existing)" : "")"
        )

        // 5. Agent: `vm agent`'s terminal, landed in the repository's workspace and
        // started in the checkout.
        var agentTerminal: String?
        var agentSurface: String?
        if let agent, let agentArgv {
            let agentLabel = String(localized: "cli.vm.clone.phase.agent", defaultValue: "Agent")
            let agentStarted = Date()
            var agentParams: [String: Any] = [
                "machine": machine,
                "command": vmAgentShellCommand(argv: agentArgv, workDirectory: remoteDir),
                "name": Self.vmAgentTerminalName(agent: agent, args: promptArgs),
                "open": open && localWorkspace != nil,
                "focus": focusValue,
            ]
            if remoteWorkspace != "?" { agentParams["remote_workspace_id"] = remoteWorkspace }
            if open, let localWorkspace { agentParams["workspace_id"] = localWorkspace }
            let agentResponse = try client.sendV2(method: "surface.new_terminal", params: agentParams, responseTimeout: 240)
            agentTerminal = agentResponse["terminal_id"] as? String
            agentSurface = (agentResponse["surface_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            phase("agent", agentLabel, agentStarted, detail: "\(agent) \(agentTerminal ?? "?")")
        }

        let address = "\(machine)/\(remoteWorkspace)"
        let summary = timings
            .map { "\($0.label) \(String(format: "%.1fs", $0.seconds))" }
            .joined(separator: " \u{00B7} ")
        if jsonOutput {
            var timingPayload: [String: Any] = [:]
            for timing in timings {
                timingPayload[timing.key] = (timing.seconds * 10).rounded() / 10
            }
            var payload: [String: Any] = [:]
            payload["machine"] = machine
            payload["created"] = selection.created
            payload["reason"] = selection.reason
            payload["repo"] = repoPayload()
            payload["dir"] = remoteDir
            payload["result"] = result
            payload["secrets_synced"] = secretsSynced
            payload["workspace_name"] = workspaceName
            payload["workspace_id"] = remoteWorkspace
            payload["existing_workspace"] = existingWorkspace
            payload["local_workspace_id"] = orNull(localWorkspace)
            payload["terminal_id"] = orNull(starterTerminal)
            payload["agent"] = orNull(agent)
            payload["agent_terminal_id"] = orNull(agentTerminal)
            payload["open"] = "cmux vm open \(address)"
            payload["timings"] = timingPayload
            if let agentSurface { payload["agent_surface_id"] = agentSurface }
            print(jsonString(payload))
            return
        }
        cliWriteStderr(summary + "\n")
        print(String(
            format: updated
                ? String(localized: "cli.vm.clone.doneUpdated", defaultValue: "Updated %1$@ in %2$@ on %3$@.")
                : String(localized: "cli.vm.clone.doneCloned", defaultValue: "Cloned %1$@ into %2$@ on %3$@."),
            spec.projectKey, remoteDir, machine
        ))
        print(String(
            format: String(localized: "cli.vm.clone.openAddress", defaultValue: "Open: cmux vm open %@"),
            address
        ))
        if let agentTerminal, let agent {
            print(String(
                format: String(localized: "cli.vm.clone.agentAddress", defaultValue: "%1$@: cmux vm open %2$@/%3$@"),
                agent, address, agentTerminal
            ))
        }
    }

    /// `vm.secrets_sync` for the machine and the repository's project, so GH_TOKEN and the
    /// project's keys are on the machine before git runs. Never throws: an app without
    /// Cloud Secrets (`method_not_found`) or a failed delivery still clones public
    /// repositories. Returns whether the sync succeeded and a short detail for the
    /// progress line; the response carries names only, never values.
    func syncVMCloneSecrets(machine: String, projectKey: String, client: SocketClient) -> (synced: Bool, detail: String) {
        let response: [String: Any]
        do {
            response = try client.sendV2(
                method: "vm.secrets_sync",
                params: ["id": machine, "project": projectKey],
                // The app bounds a sync at 240s (it may have to wake the machine's link).
                responseTimeout: 250
            )
        } catch {
            return (false, String(localized: "cli.vm.clone.secretsUnavailable", defaultValue: "unavailable"))
        }
        if let error = response["error"] as? String, !error.isEmpty {
            return (false, String(localized: "cli.vm.clone.secretsNotSynced", defaultValue: "not synced"))
        }
        if (response["noop"] as? Bool) == true {
            return (true, String(localized: "cli.vm.clone.secretsCurrent", defaultValue: "already current"))
        }
        let sent = (response["sent"] as? [String]) ?? []
        return (true, String(
            format: String(localized: "cli.vm.clone.secretsSent", defaultValue: "%d delivered"),
            sent.count
        ))
    }
}
