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
        Usage: cmux vm clone <repo> [options]       (also: cmux vm repo clone <repo> [options])

        Examples:
          cmux vm clone manaflow-ai/cmux
          cmux vm clone . --agent claude -- "run the test suite and fix failures"
          cmux vm clone https://github.com/vercel/next.js/tree/canary --new --size 16g
          cmux vm clone git@github.com:acme/api.git --machine vivid-newt --no-open --json

        Clones a repository on a Cloud machine and opens a workspace named after it, with a
        terminal in the checkout. In order: pick a machine (the one this repository used
        last, then an idle pool machine, then a new one); sync Cloud Secrets so GH_TOKEN
        reaches git; clone into work/<repo>, or fetch and check out if it is already there;
        name any secrets the repository declares that the machine lacks; run the
        repository's .cmux/cloud.json `setup` in a "setup" terminal; start --agent as a tab
        in the same workspace.

        <repo>   <owner>/<repo>, https://github.com/<owner>/<repo>[/tree/<branch>],
                 git@<host>:<path>.git (GitHub clones over https), any https git URL, or
                 `.` for this folder's origin and the branch it tracks there. Uncommitted
                 and unpushed work stays here; send it with `cmux vm push` or `cmux vm dev`.

        Options:
          --machine <id>       Use this machine instead of routing.
          --new                Use a new pool machine.
          --size <4g|8g|16g|24g|32g|64g|MB>
                               Memory for a new machine (24g and up need cmux Max).
          --branch <b>         Check out this branch (wins over /tree/<branch>).
          --dir <path>         Checkout on the machine, relative to home (default: work/<repo>).
          --agent <claude|codex|opencode|pi> [-- <prompt>]
                               Start an agent in the checkout; with a prompt it runs one-shot.
          --skip-setup         Do not run the repository's setup commands.
          --no-open            Do everything on the machine; open nothing here.
          --focus, --no-focus  \(openFocusDefaultHelp)
          --dry-run            Show the plan, including the machine it would use; change nothing.
          --json               Print {machine, repo, dir, workspace_id, terminal_id, setup,
                               agent_terminal_id, open, timings, …}.

        Private repositories: add a GitHub token once with `cmux vm secrets import --gh`.
        Setup commands come from the repository and run with your Cloud Secrets in reach;
        pass --skip-setup for a repository you do not trust.
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
            // The absolute checkout path, so terminals can start there natively (the
            // machine user's home is not known on the Mac).
            "printf 'cmux-clone-path=%s\\n' \"$(cd \"$d\" && pwd -P)\"",
            vmCloneManifestDumpScript,
            "true",
        ]
        return parts.joined(separator: "; ")
    }

    // MARK: - Repository manifest (pure)

    /// The files a checkout declares its environment in, relative to its root.
    static let vmCloneManifestPaths = [".cmux/cloud.json", ".devcontainer/devcontainer.json", ".devcontainer.json"]

    /// The largest manifest file read back from the machine.
    static let vmCloneManifestMaxBytes = 256 * 1024

    /// Appended to the clone script: after a successful clone or update, print each
    /// manifest file that exists as `cmux-manifest <path> <base64>`, so the same exec
    /// that cloned also returns what the checkout declares. Those files hold names and
    /// commands, never values. `$d` is the checkout, relative to `$HOME`.
    static var vmCloneManifestDumpScript: String {
        let paths = vmCloneManifestPaths.map(\.posixShellWord).joined(separator: " ")
        return "for f in \(paths); do p=\"$d/$f\"; "
            + "if [ -f \"$p\" ] && [ \"$(wc -c < \"$p\")\" -le \(vmCloneManifestMaxBytes) ]; then "
            + "printf 'cmux-manifest %s %s\\n' \"$f\" \"$(base64 < \"$p\" | tr -d '\\n')\"; fi; done"
    }

    /// The manifest files in the clone exec's stdout, keyed by path. Unknown paths,
    /// undecodable payloads and non-UTF-8 text are dropped.
    static func vmCloneManifestFiles(fromCloneOutput stdout: String) -> [String: String] {
        var files: [String: String] = [:]
        for line in stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("cmux-manifest ") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3 else { continue }
            let path = String(fields[1])
            guard vmCloneManifestPaths.contains(path),
                  let data = Data(base64Encoded: String(fields[2])),
                  data.count <= vmCloneManifestMaxBytes,
                  let text = String(data: data, encoding: .utf8) else { continue }
            files[path] = text
        }
        return files
    }

    /// The absolute checkout path the clone exec printed (`cmux-clone-path=/home/…`),
    /// or nil when it is missing (an older script) or not a plain absolute path.
    static func vmCloneCheckoutPath(fromCloneOutput stdout: String) -> String? {
        for line in stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("cmux-clone-path=") {
            let path = String(line.dropFirst("cmux-clone-path=".count))
            guard path.hasPrefix("/"), path.count > 1,
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return path
        }
        return nil
    }

    /// The agent's terminal program: `vm agent`'s login-shell launch in the checkout, but
    /// not `exec`, so when the agent exits (a one-shot prompt finishes, or the user quits
    /// it) the tab stays in the repository's workspace as a shell in the checkout, with
    /// the agent's output above it.
    static func vmCloneAgentShellCommand(argv: [String], dir: String) -> [String] {
        let joined = argv.map(\.posixShellWord).joined(separator: " ")
        return [
            "bash", "-lc",
            "cd \"$HOME\"; cd \(vmCloneShellDirectory(dir)) || exit 1; "
                + "export PATH=\"$HOME/.npm-global/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH\"; "
                + "\(joined); exec \"${SHELL:-bash}\" -l",
        ]
    }

    /// The `--dry-run` machine line: the pinned machine, the routed one, or "a new 4g
    /// machine" when routing would create one. `memoryMb` is the `--size` request.
    static func vmCloneDryRunMachineText(pinned: String?, forceNew: Bool, routed: VMRunSelection?, memoryMb: Int?) -> String {
        if let pinned {
            return String(format: String(localized: "cli.vm.clone.plan.machinePinned", defaultValue: "%@ (pinned with --machine)"), pinned)
        }
        let size: String
        if let memoryMb {
            size = memoryMb % 1024 == 0 ? "\(memoryMb / 1024)g" : "\(memoryMb) MB"
        } else {
            size = "4g"
        }
        let newMachine = String(format: String(localized: "cli.vm.clone.plan.machineNew", defaultValue: "a new %@ machine"), size)
        if forceNew { return newMachine + " (--new)" }
        guard let routed else {
            return String(localized: "cli.vm.clone.plan.machineRouted", defaultValue: "the one this repository used last, else an idle pool machine, else a new one")
        }
        if routed.wouldProvision { return newMachine }
        return "\(routed.id) (\(routed.reason))"
    }

    /// What `.` leaves behind, from this folder's git state: uncommitted changes and
    /// commits origin does not have. Empty when the folder is clean and pushed.
    static func vmCloneDotLocalNotes(uncommitted: Int, unpushed: Int, branch: String?) -> [String] {
        var notes: [String] = []
        let source = branch.map { "origin/\($0)" }
            ?? String(localized: "cli.vm.clone.dot.defaultBranch", defaultValue: "origin's default branch")
        if uncommitted > 0 {
            let format = uncommitted == 1
                ? String(localized: "cli.vm.clone.dot.uncommitted.one", defaultValue: "Cloning %1$@ \u{2014} %2$ld uncommitted change in this checkout is not included. Use `cmux vm push` or `cmux vm dev` to send working-tree changes.")
                : String(localized: "cli.vm.clone.dot.uncommitted.many", defaultValue: "Cloning %1$@ \u{2014} %2$ld uncommitted changes in this checkout are not included. Use `cmux vm push` or `cmux vm dev` to send working-tree changes.")
            notes.append(String(format: format, source, uncommitted))
        }
        if unpushed > 0 {
            let format = unpushed == 1
                ? String(localized: "cli.vm.clone.dot.unpushed.one", defaultValue: "%1$ld local commit is not on %2$@ yet, so the machine will not have it. Push first (git push) to include it.")
                : String(localized: "cli.vm.clone.dot.unpushed.many", defaultValue: "%1$ld local commits are not on %2$@ yet, so the machine will not have them. Push first (git push) to include them.")
            notes.append(String(format: format, unpushed, source))
        }
        return notes
    }

    /// `.cmux/cloud.json`'s `setup`: a command string or an array of them, in order.
    /// Comments and trailing commas are allowed, as in the devcontainer dialect; anything
    /// unreadable declares no setup.
    static func vmCloneSetupCommands(cloudJSON text: String?) -> [String] {
        guard let text,
              let data = vmCloneStrictJSON(text).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let raw: [Any]
        if let single = object["setup"] as? String {
            raw = [single]
        } else {
            raw = (object["setup"] as? [Any]) ?? []
        }
        return raw.compactMap { item -> String? in
            guard let command = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
            return command
        }
    }

    /// JSON-with-comments to strict JSON: `//` and `/* */` outside strings are removed and
    /// a comma before `}` or `]` is dropped (the reader Cloud Secrets uses for the same files).
    static func vmCloneStrictJSON(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output: [Unicode.Scalar] = []
        var index = 0
        var inString = false
        var escaped = false
        var pendingComma: Int?
        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                output.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
            if scalar == "/", next == "/" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
                continue
            }
            if scalar == "/", next == "*" {
                index += 2
                while index < scalars.count, !(scalars[index] == "*" && index + 1 < scalars.count && scalars[index + 1] == "/") {
                    index += 1
                }
                index += 2
                continue
            }
            if scalar == "}" || scalar == "]" {
                if let comma = pendingComma { output[comma] = " " }
                pendingComma = nil
            } else if scalar == "," {
                pendingComma = output.count
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingComma = nil
            }
            if scalar == "\"" { inString = true }
            output.append(scalar)
            index += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    // MARK: - Setup terminal (pure)

    /// The `setup` terminal's program: each command in its own subshell in the checkout,
    /// framed by `[cmux setup i/n] $ <command>` and `[cmux setup i/n] exit <code>` lines the
    /// CLI follows. It stops at the first failure, and in every case ends in an
    /// interactive login shell in the checkout, so the terminal stays open to inspect or
    /// rerun a step.
    static func vmCloneSetupScript(commands: [String], dir: String) -> String {
        let total = commands.count
        let shell = "exec \"${SHELL:-bash}\" -l"
        var lines: [String] = [
            "cd \"$HOME\" || exit 1",
            "cd \(vmCloneShellDirectory(dir)) || { printf '[cmux setup] cannot enter %s\\n' \(dir.posixShellWord); \(shell); }",
            "export PATH=\"$HOME/.npm-global/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH\"",
            "printf '[cmux setup] %s step(s) from .cmux/cloud.json\\n' \(total)",
        ]
        for (offset, command) in commands.enumerated() {
            let step = "\(offset + 1)/\(total)"
            lines.append("printf '\\n[cmux setup \(step)] $ %s\\n' \(command.posixShellWord)")
            lines.append("( eval \(command.posixShellWord) )")
            lines.append("cmux_setup_rc=$?")
            lines.append("printf '[cmux setup \(step)] exit %s\\n' \"$cmux_setup_rc\"")
            lines.append("if [ \"$cmux_setup_rc\" -ne 0 ]; then printf '[cmux setup] step \(step) failed. This shell stays open in the checkout.\\n'; \(shell); fi")
        }
        lines.append("printf '[cmux setup] done\\n'")
        lines.append(shell)
        return lines.joined(separator: "\n")
    }

    /// A `[cmux setup i/n] exit <code>` line: (step, code), else nil.
    static func vmCloneSetupExitMarker(_ line: String) -> (step: Int, code: Int)? {
        guard line.hasPrefix("[cmux setup "), let close = line.firstIndex(of: "]") else { return nil }
        let counter = line[line.index(line.startIndex, offsetBy: "[cmux setup ".count)..<close]
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard let slash = counter.firstIndex(of: "/"),
              let step = Int(counter[..<slash]),
              rest.hasPrefix("exit "),
              let code = Int(rest.dropFirst("exit ".count).trimmingCharacters(in: .whitespaces)) else { return nil }
        return (step, code)
    }

    /// Terminal output reduced to plain lines: escape sequences removed, a carriage
    /// return keeps only what was drawn after it (progress bars), blank lines dropped.
    static func vmCloneSetupPlainLines(_ text: String) -> [String] {
        let withoutEscapes = text.replacingOccurrences(
            of: "\u{1B}(\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])",
            with: "",
            options: .regularExpression
        )
        return withoutEscapes.components(separatedBy: "\n").compactMap { rawLine in
            let visible = rawLine.components(separatedBy: "\r").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            let line = CMUXCLI.vmSecretsPrintable(visible, limit: 400)
            return line.isEmpty ? nil : line
        }
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

    /// Changed, staged, and untracked paths in the folder (`git status --porcelain`).
    static func vmCloneUncommittedCount(directory: String) -> Int {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory, "status", "--porcelain"],
            timeout: 30
        )
        guard !result.timedOut, result.status == 0 else { return 0 }
        return result.stdout.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
    }

    /// Commits on HEAD that its upstream does not have; 0 without an upstream (the
    /// no-upstream note already covers that case).
    static func vmCloneUnpushedCount(directory: String) -> Int {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory, "rev-list", "--count", "@{upstream}..HEAD"],
            timeout: 30
        )
        guard !result.timedOut, result.status == 0 else { return 0 }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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
        var skipSetup = false
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
            case "--skip-setup": skipSetup = true
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
            for note in Self.vmCloneDotLocalNotes(
                uncommitted: Self.vmCloneUncommittedCount(directory: cwd),
                unpushed: Self.vmCloneUnpushedCount(directory: cwd),
                branch: spec.branch
            ) {
                cliWriteStderr(note + "\n")
            }
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
            // Which machine routing would pick, read without creating one. No socket (or
            // no sign-in) leaves the plan without it rather than failing the dry run.
            var routed: VMRunSelection?
            if machineOverride == nil, !forceNew {
                routed = try? selectVMForRun(
                    machineOverride: nil,
                    forceNew: false,
                    memoryMb: memoryMb,
                    workDirectory: routingDirectory,
                    allowProvision: false,
                    client: client
                )
            }
            let machineText = Self.vmCloneDryRunMachineText(pinned: machineOverride, forceNew: forceNew, routed: routed, memoryMb: memoryMb)
            if jsonOutput {
                var plan: [String: Any] = [:]
                plan["dry_run"] = true
                plan["repo"] = repoPayload()
                plan["dir"] = remoteDir
                plan["workspace_name"] = workspaceName
                plan["machine"] = orNull(machineOverride ?? routed.flatMap { $0.wouldProvision ? nil : $0.id })
                plan["machine_plan"] = machineText
                plan["would_provision"] = forceNew || routed?.wouldProvision == true
                plan["new"] = forceNew
                plan["agent"] = orNull(agent)
                plan["agent_command"] = orNull(agentArgv)
                plan["open"] = open
                plan["skip_setup"] = skipSetup
                print(jsonString(plan))
            } else {
                let branchText = spec.branch.map { " (branch \($0))" } ?? " (default branch)"
                print("plan: clone \(spec.cloneURL)\(branchText)")
                print("plan: project \(spec.projectKey)")
                print("plan: machine \(machineText), checkout \(remoteDir)")
                print("plan: workspace \(workspaceName) (get-or-create)\(open ? ", opened here" : ", not opened")")
                print(skipSetup
                    ? "plan: setup skipped (--skip-setup)"
                    : "plan: setup from .cmux/cloud.json `setup`, if the repository has one")
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
        let checkoutPath = Self.vmCloneCheckoutPath(fromCloneOutput: cloneStdout)
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
                    defaultValue: "vm clone: git failed on %1$@ (exit %2$ld)%3$@"
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

        // 4. What the checkout declares, read back by the clone exec itself: secret names
        // to compare with what reaches the machine (a warning, never a stop), and the
        // setup commands step 6 runs.
        let manifestFiles = Self.vmCloneManifestFiles(fromCloneOutput: cloneStdout)
        var missingSecrets: [String] = []
        if !manifestFiles.isEmpty,
           let preflight = vmSecretsPreflight(
               machine: machine,
               project: spec.projectKey,
               directory: nil,
               manifestFiles: manifestFiles,
               client: client
           ) {
            missingSecrets = preflight.missing.map(\.name)
            for line in Self.vmSecretsPreflightLines(preflight, hintUsesCurrentDirectory: false) {
                cliWriteStderr(line + "\n")
            }
        }
        let setupCommands = Self.vmCloneSetupCommands(cloudJSON: manifestFiles[".cmux/cloud.json"])

        // 5. Workspace: get-or-create by the repository's name, a terminal in the
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
        var starterTerminal = (workspaceResponse["terminal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let localWorkspace = (workspaceResponse["workspace_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // A fresh workspace's starter shell begins in the home directory. Replace it with
        // a terminal started in the checkout (a native cwd, so nothing is typed into it
        // and the sidebar shows the checkout); an existing workspace keeps whatever its
        // terminals are doing. Without the checkout's absolute path, or when the new
        // terminal cannot start, the starter is moved with `cd` as before.
        if !existingWorkspace, let starter = starterTerminal {
            var replaced = false
            if let checkoutPath {
                var params: [String: Any] = [
                    "machine": machine,
                    "cwd": checkoutPath,
                    "open": open && localWorkspace != nil,
                    "focus": focusValue,
                ]
                if remoteWorkspace != "?" { params["remote_workspace_id"] = remoteWorkspace }
                if open, let localWorkspace { params["workspace_id"] = localWorkspace }
                if let response = try? client.sendV2(method: "surface.new_terminal", params: params, responseTimeout: 240),
                   let terminal = (response["terminal_id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                    _ = try? client.sendV2(
                        method: "vm.terminal_close",
                        params: ["id": machine, "terminal_id": starter],
                        responseTimeout: 120
                    )
                    starterTerminal = terminal
                    replaced = true
                }
            }
            if !replaced {
                _ = try client.sendV2(
                    method: "vm.terminal_write",
                    params: [
                        "id": machine,
                        "terminal_id": starter,
                        "text": "cd \(Self.vmCloneShellDirectory(remoteDir))",
                        "keys": ["enter"],
                    ],
                    responseTimeout: 120
                )
            }
        }
        phase(
            "workspace",
            workspaceLabel,
            workspaceStarted,
            detail: "\(workspaceName) \(remoteWorkspace)\(existingWorkspace ? " (existing)" : "")"
        )

        // 6. Setup: the manifest's commands in a visible "setup" terminal, followed here
        // step by step. A failure stops before the agent and leaves the terminal open.
        var setupOutcome: VMCloneSetupOutcome?
        if !setupCommands.isEmpty {
            let shown = setupCommands.map { Self.vmSecretsPrintable($0, limit: 60) }.joined(separator: "; ")
            if skipSetup {
                cliWriteStderr(String(
                    format: String(localized: "cli.vm.clone.setup.skipped", defaultValue: "Setup skipped (--skip-setup): %1$@"),
                    shown
                ) + "\n")
            } else {
                let setupLabel = String(localized: "cli.vm.clone.phase.setup", defaultValue: "Setup")
                let setupStarted = Date()
                cliWriteStderr(String(
                    format: String(localized: "cli.vm.clone.setup.plan", defaultValue: "Setup from .cmux/cloud.json in terminal \"setup\": %1$@"),
                    shown
                ) + "\n")
                let outcome = try runVMCloneSetup(
                    machine: machine,
                    remoteWorkspace: remoteWorkspace == "?" ? nil : remoteWorkspace,
                    localWorkspace: localWorkspace,
                    open: open,
                    remoteDir: remoteDir,
                    checkoutPath: checkoutPath,
                    commands: setupCommands,
                    client: client
                )
                setupOutcome = outcome
                phase(
                    "setup",
                    setupLabel,
                    setupStarted,
                    detail: outcome.failure == nil
                        ? String(format: String(localized: "cli.vm.clone.setup.doneDetail", defaultValue: "%ld step(s) in terminal %@"), outcome.steps.count, outcome.terminalID)
                        : String(format: String(localized: "cli.vm.clone.setup.failedDetail", defaultValue: "stopped in terminal %@"), outcome.terminalID)
                )
            }
        }
        let setupFailed = setupOutcome?.failure != nil

        // 7. Agent: `vm agent`'s terminal, landed in the repository's workspace and
        // started in the checkout, once setup succeeded.
        var agentTerminal: String?
        var agentSurface: String?
        if !setupFailed, let agent, let agentArgv {
            let agentLabel = String(localized: "cli.vm.clone.phase.agent", defaultValue: "Agent")
            let agentStarted = Date()
            var agentParams: [String: Any] = [
                "machine": machine,
                // A tab in the repository's workspace that outlives the agent: when it
                // exits, a shell in the checkout keeps the tab (and its output) there.
                "command": Self.vmCloneAgentShellCommand(argv: agentArgv, dir: remoteDir),
                "name": Self.vmAgentTerminalName(agent: agent, args: promptArgs),
                "open": open && localWorkspace != nil,
                "focus": focusValue,
            ]
            if remoteWorkspace != "?" { agentParams["remote_workspace_id"] = remoteWorkspace }
            if open, let localWorkspace { agentParams["workspace_id"] = localWorkspace }
            if let checkoutPath { agentParams["cwd"] = checkoutPath }
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
            payload["missing_secrets"] = missingSecrets
            payload["setup"] = Self.vmCloneSetupPayload(
                commands: setupCommands,
                skipped: skipSetup,
                outcome: setupOutcome
            )
            if let agentSurface { payload["agent_surface_id"] = agentSurface }
            print(jsonString(payload))
            if let setupOutcome, setupFailed {
                throw vmCloneSetupFailure(setupOutcome, machine: machine, address: address, repoArg: repoArg)
            }
            return
        }
        cliWriteStderr(summary + "\n")
        if let setupOutcome, setupFailed {
            throw vmCloneSetupFailure(setupOutcome, machine: machine, address: address, repoArg: repoArg)
        }
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

    // MARK: - Setup run

    /// How long the CLI follows setup before it stops waiting (the terminal keeps going).
    static let vmCloneSetupTimeoutSeconds: TimeInterval = 3600
    /// One blocking `vm.terminal_wait` slice: the longest the live line goes unrefreshed.
    static let vmCloneSetupSliceMs = 2_000
    /// Silence after which the CLI says a step is still running.
    static let vmCloneSetupStallSeconds: TimeInterval = 60

    struct VMCloneSetupOutcome {
        struct Step {
            let command: String
            let seconds: Double
            let exitCode: Int
        }

        let terminalID: String
        var steps: [Step] = []
        /// Why setup stopped; nil when every step exited 0.
        var failure: String?
        var exitCode: Int32 = 0
    }

    /// Starts the "setup" terminal in the repository's workspace and follows it: blocks
    /// on the screen showing the current step's exit line (`vm.terminal_wait`, short
    /// slices), reads the new output (`vm.terminal_output` from the last offset), and
    /// prints one timed line per finished step. On a terminal, a live line shows the
    /// running step, its elapsed time and the last output line; after a minute without
    /// output it says the step is still running. Stops at the first failing step.
    func runVMCloneSetup(
        machine: String,
        remoteWorkspace: String?,
        localWorkspace: String?,
        open: Bool,
        remoteDir: String,
        checkoutPath: String? = nil,
        commands: [String],
        client: SocketClient
    ) throws -> VMCloneSetupOutcome {
        var params: [String: Any] = [
            "machine": machine,
            "command": ["bash", "-lc", Self.vmCloneSetupScript(commands: commands, dir: remoteDir)],
            "name": "setup",
            "open": open && localWorkspace != nil,
            // Visible in the workspace, but the agent (or the user) keeps focus.
            "focus": false,
        ]
        if let remoteWorkspace { params["remote_workspace_id"] = remoteWorkspace }
        if open, let localWorkspace { params["workspace_id"] = localWorkspace }
        if let checkoutPath { params["cwd"] = checkoutPath }
        let response = try client.sendV2(method: "surface.new_terminal", params: params, responseTimeout: 240)
        guard let terminalID = (response["terminal_id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw CLIError(message: String(
                format: String(localized: "cli.vm.clone.setup.noTerminal", defaultValue: "vm clone: %@ did not start the setup terminal. Rerun with --skip-setup to clone without it."),
                machine
            ))
        }

        let total = commands.count
        let live = isatty(STDERR_FILENO) == 1
        var outcome = VMCloneSetupOutcome(terminalID: terminalID)
        var offset = 0
        var pending = ""
        var stepStarted = Date()
        var lastOutputAt = Date()
        var stallNoticed = false
        var lastLine = ""
        var liveShown = false
        let deadline = Date().addingTimeInterval(Self.vmCloneSetupTimeoutSeconds)

        func label(_ index: Int) -> String {
            Self.vmSecretsPrintable(commands[index], limit: 60)
        }
        func clearLive() {
            if liveShown { cliWriteStderr("\r\u{1B}[K") }
            liveShown = false
        }
        /// Records the current step's exit; true when setup should stop.
        func finishStep(code: Int, at now: Date) -> Bool {
            let index = outcome.steps.count
            let seconds = now.timeIntervalSince(stepStarted)
            outcome.steps.append(.init(command: commands[index], seconds: seconds, exitCode: code))
            clearLive()
            let elapsed = String(format: "%.1fs", seconds)
            if code == 0 {
                cliWriteStderr(String(
                    format: String(localized: "cli.vm.clone.setup.stepDone", defaultValue: "Setup %1$ld/%2$ld %3$@ \u{2026} %4$@ \u{2713}"),
                    index + 1, total, label(index), elapsed
                ) + "\n")
            } else {
                cliWriteStderr(String(
                    format: String(localized: "cli.vm.clone.setup.stepFailed", defaultValue: "Setup %1$ld/%2$ld %3$@ \u{2026} %4$@ \u{2717} exit %5$ld"),
                    index + 1, total, label(index), elapsed, code
                ) + "\n")
                outcome.failure = String(
                    format: String(localized: "cli.vm.clone.setup.stepFailure", defaultValue: "setup step %1$ld/%2$ld `%3$@` exited %4$ld"),
                    index + 1, total, label(index), code
                )
                outcome.exitCode = Int32((1...255).contains(code) ? code : 1)
                return true
            }
            stepStarted = now
            lastOutputAt = now
            stallNoticed = false
            lastLine = ""
            return false
        }

        while outcome.steps.count < total {
            let step = outcome.steps.count + 1
            let wait = waitForVMCloneSetupStep(
                machine: machine,
                terminalID: terminalID,
                pattern: "\\[cmux setup \(step)/\(total)\\] exit [0-9]+",
                client: client
            )
            let page = try readVMCloneSetupOutput(machine: machine, terminalID: terminalID, after: offset, client: client)
            offset = page.next
            let now = Date()
            if !page.text.isEmpty {
                var parts = (pending + page.text).components(separatedBy: "\n")
                pending = parts.removeLast()
                lastOutputAt = now
                stallNoticed = false
                for line in Self.vmCloneSetupPlainLines(parts.joined(separator: "\n")) {
                    if let marker = Self.vmCloneSetupExitMarker(line) {
                        guard marker.step == outcome.steps.count + 1 else { continue }
                        if finishStep(code: marker.code, at: now) { return outcome }
                        if outcome.steps.count == total { break }
                    } else if !line.hasPrefix("[cmux setup") {
                        lastLine = line
                    }
                }
                if let partial = Self.vmCloneSetupPlainLines(pending).last { lastLine = partial }
            }
            // The screen showed this step's exit line but the output stream did not (its
            // retention was trimmed): take the exit code from the screen.
            if wait.matched, outcome.steps.count + 1 == step,
               let marker = Self.vmCloneSetupPlainLines(wait.screen).compactMap(Self.vmCloneSetupExitMarker).last(where: { $0.step == step }) {
                if finishStep(code: marker.code, at: now) { return outcome }
            }
            if outcome.steps.count == total { break }
            let current = outcome.steps.count
            if wait.exited {
                clearLive()
                outcome.failure = String(
                    format: String(localized: "cli.vm.clone.setup.exited", defaultValue: "the setup terminal closed during step %1$ld/%2$ld `%3$@`"),
                    current + 1, total, label(current)
                )
                outcome.exitCode = 1
                return outcome
            }
            let silent = now.timeIntervalSince(lastOutputAt)
            if !stallNoticed, silent >= Self.vmCloneSetupStallSeconds {
                clearLive()
                cliWriteStderr(String(
                    format: String(localized: "cli.vm.clone.setup.stalled", defaultValue: "Setup %1$ld/%2$ld: still running `%3$@` (no output %4$lds)"),
                    current + 1, total, label(current), Int(silent)
                ) + "\n")
                stallNoticed = true
            }
            if now >= deadline {
                clearLive()
                outcome.failure = String(
                    format: String(localized: "cli.vm.clone.setup.timedOut", defaultValue: "setup step %1$ld/%2$ld `%3$@` was still running after %4$ld minutes (not stopped)"),
                    current + 1, total, label(current), Int(Self.vmCloneSetupTimeoutSeconds / 60)
                )
                outcome.exitCode = 1
                return outcome
            }
            if live {
                var text = String(
                    format: String(localized: "cli.vm.clone.setup.running", defaultValue: "Setup %1$ld/%2$ld %3$@ \u{2026} %4$@"),
                    current + 1, total, label(current), String(format: "%.1fs", now.timeIntervalSince(stepStarted))
                )
                if !lastLine.isEmpty { text += "  " + Self.vmSecretsPrintable(lastLine, limit: 60) }
                cliWriteStderr("\r\u{1B}[K" + text)
                liveShown = true
            }
        }
        clearLive()
        return outcome
    }

    /// Blocks until the screen shows `pattern` or one slice passes. When the wait cannot
    /// run (the terminal ended, or an older machine), blocks on the process instead
    /// (`vm.terminal_wait_exit`, same slice) so the follow loop never spins; `exited`
    /// reports a terminal whose shell is gone.
    func waitForVMCloneSetupStep(machine: String, terminalID: String, pattern: String, client: SocketClient) -> (matched: Bool, screen: String, exited: Bool) {
        let slice = Self.vmCloneSetupSliceMs
        do {
            let response = try client.sendV2(
                method: "vm.terminal_wait",
                params: ["id": machine, "terminal_id": terminalID, "pattern": pattern, "timeout_ms": slice],
                responseTimeout: TimeInterval(slice / 1000 + 60)
            )
            return ((response["matched"] as? Bool) == true, (response["text"] as? String) ?? "", (response["exited"] as? Bool) == true)
        } catch {
            guard let response = try? client.sendV2(
                method: "vm.terminal_wait_exit",
                params: ["id": machine, "terminal_id": terminalID, "timeout_ms": slice],
                responseTimeout: TimeInterval(slice / 1000 + 60)
            ) else {
                return (false, "", true)
            }
            return (false, "", (response["state"] as? String) == "exited")
        }
    }

    /// One `vm.terminal_output` window after `after`, and the offset to read from next.
    func readVMCloneSetupOutput(machine: String, terminalID: String, after: Int, client: SocketClient) throws -> (text: String, next: Int) {
        let response = try client.sendV2(
            method: "vm.terminal_output",
            params: ["id": machine, "terminal_id": terminalID, "after": after],
            responseTimeout: 120
        )
        let text = (response["text"] as? String) ?? ""
        let next = (response["next_offset"] as? Int)
            ?? (response["next_offset"] as? String).flatMap(Int.init)
            ?? (after + text.utf8.count)
        return (text, max(after, next))
    }

    /// `setup` in the JSON result: `none` (nothing declared), `skipped`, `done`, or `failed`.
    static func vmCloneSetupPayload(commands: [String], skipped: Bool, outcome: VMCloneSetupOutcome?) -> [String: Any] {
        let status: String
        if commands.isEmpty {
            status = "none"
        } else if outcome == nil {
            status = skipped ? "skipped" : "none"
        } else {
            status = outcome?.failure == nil ? "done" : "failed"
        }
        var payload: [String: Any] = ["status": status, "commands": commands]
        if let outcome {
            payload["terminal_id"] = outcome.terminalID
            payload["steps"] = outcome.steps.map { step -> [String: Any] in
                ["command": step.command, "seconds": (step.seconds * 10).rounded() / 10, "exit_code": step.exitCode]
            }
            if let failure = outcome.failure { payload["error"] = failure }
        }
        return payload
    }

    /// The error a failed setup ends the run with: what failed, where the terminal is,
    /// and the rerun that skips setup.
    func vmCloneSetupFailure(_ outcome: VMCloneSetupOutcome, machine: String, address: String, repoArg: String) -> CLIError {
        let reason = outcome.failure ?? ""
        let message = [
            String(
                format: String(localized: "cli.vm.clone.setup.failed", defaultValue: "vm clone: %1$@ on %2$@. The \"setup\" terminal stays open in the checkout."),
                reason, machine
            ),
            String(
                format: String(localized: "cli.vm.clone.setup.openTerminal", defaultValue: "Open: cmux vm open %@"),
                "\(address)/\(outcome.terminalID)"
            ),
            String(
                format: String(localized: "cli.vm.clone.setup.rerun", defaultValue: "Rerun without setup: cmux vm clone %1$@ --machine %2$@ --skip-setup"),
                repoArg.posixShellWord, machine
            ),
        ].joined(separator: "\n")
        return CLIError(message: message, exitCode: outcome.exitCode)
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
            format: String(localized: "cli.vm.clone.secretsSent", defaultValue: "%ld delivered"),
            sent.count
        ))
    }
}
