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
        terminal in the checkout. In order: pick a machine (--machine; else the one this
        repository used last; else your only running machine, said so on stderr; else an
        idle pool machine; else a new one, whose first workspace is named for the
        repository); sync Cloud Secrets so GH_TOKEN
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
          --new                Use a new pool machine, even when one of yours is running.
          --size <4g|8g|16g|24g|32g|64g|MB>
                               Memory for a new machine (24g and up need cmux Max).
          --branch <b>         Check out this branch (wins over /tree/<branch>).
          --dir <path>         Checkout on the machine, relative to home (default: work/<repo>).
                               Its workspace is named "<repo> (<dir name>)".
          --agent <claude|codex|opencode|pi> [-- <prompt>]
                               Start an agent in the checkout; with a prompt it runs one-shot.
          --setup              Run the repository's setup commands without asking (also
                               on a checkout that already existed).
          --skip-setup         Do not run the repository's setup commands.
          --save-warm          After setup, save the machine as this repository's warm start
                               (a snapshot, before --agent starts).
          --cold               Do not start from the repository's warm start.
          --no-open            Do everything on the machine; open nothing here.
          --focus, --no-focus  \(openFocusDefaultHelp)
          --dry-run            Show the plan, including the machine it would use; change nothing.
          --json               Print {machine, repo, dir, workspace_id, terminal_id, setup,
                               agent_terminal_id, open, timings, …}.

        Private repositories: add a GitHub token once with `cmux vm secrets import --gh`.
        Setup commands come from the repository and run with your Cloud Secrets in reach,
        so only `.` (your own checkout) runs them on its own. For any other repository
        the commands are listed and, on a terminal, you are asked first; without a
        terminal they are skipped unless you pass --setup. A checkout that already
        existed is only updated: its setup runs again only with --setup.

        Warm starts: when the clone needs a new machine (--new, or nothing to reuse) and
        the repository has a warm start, the machine is restored from that snapshot (its
        checkout, dependencies and workspace) and the checkout is fetched, instead of a
        fresh machine, clone and setup. A snapshot that cannot be restored falls back to
        a fresh machine with a one-line note. Save one with --save-warm, or put
        "warm": true in .cmux/cloud.json to save one after the first successful setup.
        The restored machine's ~/.config/cmux/env is cleared and Cloud Secrets are
        delivered again. A paused machine is woken first ("Waking <machine>… 2.3s").
        `cmux vm snapshot warm` lists warm starts; `cmux vm snapshot warm rm <repo>` forgets one.
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

        /// `owner/repo` (or the bare name) for messages.
        var displayName: String { owner.map { "\($0)/\(name)" } ?? name }
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
            vmCloneRedactedRepoArgument(text)
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
    /// The repository argument as an error may echo it: any `user:password@` (or token)
    /// before the host of a `scheme://` URL becomes `***@`, so a pasted credential never
    /// lands in a terminal scrollback or a log.
    static func vmCloneRedactedRepoArgument(_ text: String) -> String {
        guard let schemeEnd = text.range(of: "://") else { return text }
        let afterScheme = text[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        guard let at = afterScheme[..<authorityEnd].lastIndex(of: "@") else { return text }
        return String(text[..<schemeEnd.upperBound]) + "***" + String(afterScheme[at...])
    }

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
        guard !dir.isEmpty, dir != "/", !dir.hasPrefix("-"),
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

    /// The machine workspace a checkout opens in, found again by this name on the next
    /// clone. The default checkout (`work/<repo>`) uses the repository's name; any other
    /// `--dir` adds the directory, so two checkouts of one repository never share (and
    /// never reuse) one workspace: `api (x)` for `work/x`, `api (other/api)` when only
    /// the parent differs.
    static func vmCloneWorkspaceName(name: String, dir: String) -> String {
        if dir == "work/\(name)" { return name }
        let last = dir.split(separator: "/").last.map(String.init) ?? dir
        return last.isEmpty || last == name ? "\(name) (\(dir))" : "\(name) (\(last))"
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
    static func vmCloneDryRunMachineText(pinned: String?, forceNew: Bool, routed: VMRunSelection?, routedLabel: String? = nil, memoryMb: Int?) -> String {
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
            return String(localized: "cli.vm.clone.plan.machineRouted", defaultValue: "the one this repository used last, else your only running machine, else an idle pool machine, else a new one")
        }
        if routed.wouldProvision { return newMachine }
        // The label people know the machine by (`vm ls`); the JSON plan keeps the id.
        return "\(routedLabel ?? routed.id) (\(routed.reason))"
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

    // MARK: - Machine choice

    /// Which rule picked the machine, for the stderr note and the JSON payload.
    enum VMCloneMachinePick: Equatable {
        /// `--machine` or `--new`: the router's own answer.
        case explicit
        /// The machine this repository (or `.` folder) was cloned onto last.
        case sticky
        /// The person's only awake machine that the router did not create.
        case onlyRunning
        /// `vm run`'s pool router: an idle pool machine, a sleeper, or a new one.
        case router
        /// A new machine restored from the repository's warm start.
        case warm
    }

    /// The machine `vm clone` uses, with its label and the rule that chose it.
    struct VMCloneSelection {
        let run: VMRunSelection
        let pick: VMCloneMachinePick
        /// The machine's label from `vm.list`, when it has one.
        let label: String?
        /// The machine's status in the `vm.list` the choice was read from, when known.
        var status: String? = nil
        /// The label when it names only this machine (``vmCloneAddressLabel``), so the
        /// `cmux vm open <label>/<ws>` lines can use it instead of the id.
        var addressLabel: String? = nil

        var id: String { run.id }
        var created: Bool { run.created }
        var reason: String { run.reason }
        var wouldProvision: Bool { run.wouldProvision }
    }

    /// The clone-specific step before `vm run`'s router, read from one `vm.list`: the
    /// machine this repository was cloned onto last (whoever created it, since a
    /// clone onto it was an explicit choice), then the person's only running machine.
    /// A clone is an explicit request for a checkout, unlike `vm run` drafting a pool
    /// machine for a command, so a machine they made by hand and left running is the
    /// least surprising place for it; `--new` opts out. Several running machines are
    /// not guessed between: the router (pool, then a new machine) decides. Pure.
    static func vmCloneMachinePick(
        vms: [[String: Any]],
        poolIDs: Set<String>,
        boundMachine: String?
    ) -> (pick: VMCloneMachinePick, id: String)? {
        func status(_ vm: [String: Any]) -> String { ((vm["status"] as? String) ?? "").lowercased() }
        if let boundMachine,
           let bound = vms.first(where: { ($0["id"] as? String) == boundMachine }),
           ["running", "ready", "standby", "paused"].contains(status(bound)) {
            return (.sticky, boundMachine)
        }
        let running = vms.filter { vm in
            guard let id = vm["id"] as? String, !id.isEmpty, !poolIDs.contains(id) else { return false }
            // Base is its own persistent workspace (`vm base open`), not a place for checkouts.
            if let base = vm["base"], !(base is NSNull) { return false }
            return ["running", "ready"].contains(status(vm))
        }
        guard running.count == 1, let id = running[0]["id"] as? String else { return nil }
        return (.onlyRunning, id)
    }

    /// The label `vm ls` shows for a machine, when it has one.
    static func vmCloneMachineLabel(_ id: String, vms: [[String: Any]]) -> String? {
        guard let vm = vms.first(where: { ($0["id"] as? String) == id }) else { return nil }
        return [vm["displayName"], vm["slug"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty && $0 != id }
    }

    /// The machine's label when it is a usable address: it resolves back to exactly this
    /// machine (no other machine's id or label is spelled that way) and contains nothing
    /// an `<m>/<ws>/<term>` address splits on. Nil otherwise, and the id is used.
    static func vmCloneAddressLabel(_ id: String, vms: [[String: Any]]) -> String? {
        guard let label = vmCloneMachineLabel(id, vms: vms),
              !label.contains(where: { $0 == "/" || $0 == ":" || $0.isWhitespace }),
              VMMachineSelectorResolver().resolve(label, vms: vms) == .label(id: id) else { return nil }
        return label
    }

    /// The status `vm ls` shows for a machine, when the list carries it.
    static func vmCloneMachineStatus(_ id: String, vms: [[String: Any]]) -> String? {
        (vms.first { ($0["id"] as? String) == id }?["status"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    /// `--machine` > the repository's machine > the person's only running machine >
    /// `vm run`'s router (idle pool machine, sleeper, new pool machine). The router's
    /// policy itself is unchanged: it still never drafts a hand-made machine.
    func selectVMForClone(
        machineOverride: String?,
        pinnedLabel: String? = nil,
        pinnedAddressLabel: String? = nil,
        forceNew: Bool,
        memoryMb: Int?,
        routingDirectory: String,
        allowProvision: Bool = true,
        client: SocketClient
    ) throws -> VMCloneSelection {
        func routed(_ pick: VMCloneMachinePick, vms: [[String: Any]]) throws -> VMCloneSelection {
            let run = try selectVMForRun(
                machineOverride: machineOverride,
                forceNew: forceNew,
                memoryMb: memoryMb,
                workDirectory: routingDirectory,
                allowProvision: allowProvision,
                client: client
            )
            return VMCloneSelection(
                run: run,
                pick: pick,
                label: pinnedLabel ?? Self.vmCloneMachineLabel(run.id, vms: vms),
                status: run.created ? nil : Self.vmCloneMachineStatus(run.id, vms: vms),
                addressLabel: pinnedAddressLabel ?? Self.vmCloneAddressLabel(run.id, vms: vms)
            )
        }
        if machineOverride != nil || forceNew { return try routed(.explicit, vms: []) }
        // An app that cannot list leaves the decision to the router, which says why.
        guard let listed = try? client.sendV2(method: "vm.list", responseTimeout: 60),
              let vms = listed["vms"] as? [[String: Any]] else { return try routed(.router, vms: []) }
        let binding = Self.loadVMRunBindings()[Self.vmRunWorkKey(forDirectory: routingDirectory)]
        guard let choice = Self.vmCloneMachinePick(vms: vms, poolIDs: Self.loadVMRunPool(), boundMachine: binding?.machine) else {
            return try routed(.router, vms: vms)
        }
        let reason = choice.pick == .sticky
            ? "reused, holds this repository's checkout"
            : "your only running machine"
        return VMCloneSelection(
            run: VMRunSelection(id: choice.id, created: false, reason: reason),
            pick: choice.pick,
            label: Self.vmCloneMachineLabel(choice.id, vms: vms),
            status: Self.vmCloneMachineStatus(choice.id, vms: vms),
            addressLabel: Self.vmCloneAddressLabel(choice.id, vms: vms)
        )
    }

    /// `--machine <id|label>` → the machine id and its label, through the resolver every
    /// `cmux vm` verb uses. An unknown machine is an error before anything runs; an app
    /// that cannot list machines gets the argument as typed (it then names the failure).
    func resolveVMCloneMachine(_ selector: String, client: SocketClient) throws -> (id: String, label: String?, status: String?, addressLabel: String?) {
        guard let listed = try? client.sendV2(method: "vm.list", responseTimeout: 60),
              let vms = listed["vms"] as? [[String: Any]] else { return (selector, nil, nil, nil) }
        switch VMMachineSelectorResolver().resolve(selector, vms: vms) {
        case .id(let id), .label(id: let id):
            return (
                id,
                Self.vmCloneMachineLabel(id, vms: vms),
                Self.vmCloneMachineStatus(id, vms: vms),
                Self.vmCloneAddressLabel(id, vms: vms)
            )
        case .ambiguous(let matches):
            let list = matches.map { "  \($0.id)  \($0.label)" }.joined(separator: "\n")
            throw CLIError(message: String(
                format: String(localized: "cli.vm.machineLabel.ambiguous", defaultValue: "%1$@ is the label of more than one machine; use an id:\n%2$@"),
                selector, list
            ))
        case .unknown:
            throw CLIError(message: String(
                format: String(localized: "cli.vm.clone.unknownMachine", defaultValue: "vm clone: no machine named %@. Run `cmux vm ls` to see your machines."),
                selector
            ))
        }
    }

    /// Names a just-provisioned machine's first workspace for the repository when it is
    /// still the daemon's untouched counter workspace
    /// (`CloudInitialWorkspaceName.adoptableInitialWorkspaceID`). Returns that workspace
    /// and its idle starter shell, or nil to create the repository's workspace beside
    /// it as before (an unreadable catalog, a renamed or second workspace, a failed rename).
    func adoptVMCloneInitialWorkspace(machine: String, name: String, client: SocketClient) -> (workspaceID: String, starterTerminal: String?)? {
        guard let catalog = try? client.sendV2(method: "vm.tree", params: ["id": machine, "refresh": true], responseTimeout: 120),
              let payload = VMRemoteWorkspaceResolver().vmMachinePayload(machine, from: catalog),
              let rawWorkspaces = payload["remote_workspaces"] as? [[String: Any]] else { return nil }
        let workspaces = rawWorkspaces.compactMap { workspace -> (id: String, name: String)? in
            guard let id = workspace["id"] as? String, let name = workspace["name"] as? String else { return nil }
            return (id: id, name: name)
        }
        guard let workspaceID = CloudInitialWorkspaceName.adoptableInitialWorkspaceID(workspaces) else { return nil }
        let starter: String?
        switch VMRemoteWorkspaceResolver().resolveVMMachineTerminal(machine: machine, catalog: catalog) {
        case .resolved(let resolvedWorkspace, let terminal, _) where resolvedWorkspace == workspaceID:
            starter = terminal
        case .empty:
            starter = nil
        default:
            return nil
        }
        guard (try? client.sendV2(
            method: "vm.workspace_rename",
            params: ["id": machine, "workspace_id": workspaceID, "name": name],
            responseTimeout: 120
        )) != nil else { return nil }
        return (workspaceID, starter)
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
        if branch == nil, git(["rev-parse", "--abbrev-ref", "HEAD"]) == "HEAD" {
            // A detached HEAD (a tag, a bisect, a CI checkout) names no branch to follow.
            let commit = git(["rev-parse", "--short", "HEAD"]) ?? "HEAD"
            cliWriteStderr(String(
                format: String(
                    localized: "cli.vm.clone.dotDetachedHead",
                    defaultValue: "Note: this checkout is on a detached HEAD (%1$@), so the machine clones origin's default branch, not that commit. Pass --branch <name> to clone a branch."
                ),
                commit
            ) + "\n")
        } else if branch == nil,
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
        var forceSetup = false
        var saveWarm = false
        var cold = false
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
            case "--setup": forceSetup = true
            case "--save-warm": saveWarm = true
            case "--cold": cold = true
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
        if forceSetup, skipSetup {
            throw CLIError(message: "vm clone: --setup and --skip-setup are exclusive\n\n\(Self.vmCloneUsage)")
        }
        // `--machine <label>` becomes the id before anything runs: the clone sends several
        // requests to the machine, so the lazy retry every other verb uses would repeat them.
        var pinnedLabel: String?
        var pinnedStatus: String?
        var pinnedAddressLabel: String?
        if let typed = machineOverride {
            let resolved = try resolveVMCloneMachine(typed, client: client)
            machineOverride = resolved.id
            pinnedLabel = resolved.label
            pinnedStatus = resolved.status
            pinnedAddressLabel = resolved.addressLabel
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
        let workspaceName = Self.vmCloneWorkspaceName(name: spec.name, dir: remoteDir)
        let open = !noOpen
        let focusValue = focus ?? Self.defaultFocusForUserOpen()
        // The repository's warm start replaces only a new machine: a pinned machine,
        // --cold, and an explicit --size (a warm start keeps the size it was saved at)
        // never restore one.
        let warmStart: VMWarmStart? = (cold || machineOverride != nil || memoryMb != nil)
            ? nil
            : Self.loadVMWarmStarts()[spec.projectKey]

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
            var routed: VMCloneSelection?
            if machineOverride == nil, !forceNew {
                routed = try? selectVMForClone(
                    machineOverride: nil,
                    pinnedLabel: nil,
                    forceNew: false,
                    memoryMb: memoryMb,
                    routingDirectory: routingDirectory,
                    allowProvision: false,
                    client: client
                )
            }
            let machineText = Self.vmCloneDryRunMachineText(
                pinned: pinnedLabel ?? machineOverride,
                forceNew: forceNew,
                routed: routed?.run,
                routedLabel: routed?.label,
                memoryMb: memoryMb
            )
            // Unknown routing (no app to ask) still names the warm start a new machine would use.
            let plannedWarm = warmStart.flatMap { warm in
                forceNew || routed == nil || routed?.wouldProvision == true ? warm : nil
            }
            if jsonOutput {
                var plan: [String: Any] = [:]
                plan["dry_run"] = true
                plan["repo"] = repoPayload()
                plan["dir"] = remoteDir
                plan["workspace_name"] = workspaceName
                plan["machine"] = orNull(machineOverride ?? routed.flatMap { $0.wouldProvision ? nil : $0.id })
                plan["machine_label"] = orNull(pinnedLabel ?? routed.flatMap { $0.wouldProvision ? nil : $0.label })
                plan["machine_plan"] = machineText
                plan["would_provision"] = forceNew || routed?.wouldProvision == true
                plan["new"] = forceNew
                plan["agent"] = orNull(agent)
                plan["agent_command"] = orNull(agentArgv)
                plan["open"] = open
                plan["skip_setup"] = skipSetup
                plan["setup"] = Self.vmCloneSetupPlanValue(isOwnCheckout: repoArg == ".", forceSetup: forceSetup, skipSetup: skipSetup)
                plan["warm_start"] = orNull(plannedWarm.map { warm -> [String: Any] in
                    [
                        "snapshot_id": warm.snapshotID,
                        "saved_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(warm.createdAtUnix))),
                        "if_new_machine": routed == nil && !forceNew,
                    ]
                })
                plan["save_warm"] = saveWarm
                print(jsonString(plan))
            } else {
                let branchText = spec.branch.map { " (branch \($0))" } ?? " (default branch)"
                print("plan: clone \(spec.cloneURL)\(branchText)")
                print("plan: project \(spec.projectKey)")
                print("plan: machine \(machineText), checkout \(remoteDir)")
                if let plannedWarm {
                    print("plan: warm start from snapshot \(plannedWarm.snapshotID) (saved \(Self.vmWarmStartAge(createdAtUnix: plannedWarm.createdAtUnix)))\(routed == nil && !forceNew ? " when a new machine is needed" : "")")
                }
                print("plan: workspace \(workspaceName) (get-or-create)\(open ? ", opened here" : ", not opened")")
                switch Self.vmCloneSetupPlanValue(isOwnCheckout: repoArg == ".", forceSetup: forceSetup, skipSetup: skipSetup) {
                case "skip":
                    print("plan: setup skipped (--skip-setup)")
                case "run":
                    print(forceSetup
                        ? "plan: setup from .cmux/cloud.json `setup` (--setup), if the repository has one"
                        : "plan: setup from .cmux/cloud.json `setup` on a new checkout, if the repository has one")
                default:
                    print("plan: setup from .cmux/cloud.json `setup` only after you confirm it at the prompt, or with --setup")
                }
                if saveWarm {
                    print("plan: save a warm start of the machine after setup (--save-warm)")
                }
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

        // 1. Machine: --machine, this repository's machine, the person's only running
        // machine, then `vm agent`'s router (selectVMForClone).
        let machineLabel = String(localized: "cli.vm.clone.phase.machine", defaultValue: "Machine")
        let machineStarted = Date()
        func routeMachine(allowProvision: Bool) throws -> VMCloneSelection {
            try selectVMForClone(
                machineOverride: machineOverride,
                pinnedLabel: pinnedLabel,
                pinnedAddressLabel: pinnedAddressLabel,
                forceNew: forceNew,
                memoryMb: memoryMb,
                routingDirectory: routingDirectory,
                allowProvision: allowProvision,
                client: client
            )
        }
        // A warm start stands in for the router's new machine only: the machine this
        // repository used, a running one, or an idle pool machine still come first.
        // A restore that fails never blocks the clone; it falls back to a fresh machine.
        let selection: VMCloneSelection
        var warmPayload: [String: Any]?
        var warmRestored: VMWarmStart?
        if let warmStart {
            let routed = try routeMachine(allowProvision: false)
            if routed.wouldProvision {
                let restoreStarted = Date()
                let restored = restoreVMCloneWarmStart(warmStart, project: spec.projectKey, client: client)
                let age = Self.vmWarmStartAge(createdAtUnix: warmStart.createdAtUnix)
                if let id = restored.id {
                    let seconds = Date().timeIntervalSince(restoreStarted)
                    cliWriteStderr(String(
                        format: String(localized: "cli.vm.clone.warm.restored", defaultValue: "Warm start from snapshot (saved %1$@) %2$@"),
                        age, String(format: "%.1fs", seconds)
                    ) + "\n")
                    warmRestored = warmStart
                    warmPayload = [
                        "status": "restored",
                        "snapshot_id": warmStart.snapshotID,
                        "saved_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(warmStart.createdAtUnix))),
                        "seconds": (seconds * 10).rounded() / 10,
                    ]
                    selection = VMCloneSelection(
                        run: VMRunSelection(id: id, created: true, reason: "warm start from \(warmStart.snapshotID), saved \(age)"),
                        pick: .warm,
                        label: nil,
                        status: "running"
                    )
                } else {
                    let reason = restored.failure ?? ""
                    cliWriteStderr(String(
                        format: String(
                            localized: "cli.vm.clone.warm.fallback",
                            defaultValue: "Warm start from snapshot %1$@ failed (%2$@); cloning on a fresh machine instead."
                        ),
                        warmStart.snapshotID, reason
                    ) + "\n")
                    warmPayload = ["status": "failed", "snapshot_id": warmStart.snapshotID, "reason": reason]
                    selection = try routeMachine(allowProvision: true)
                }
            } else {
                selection = routed
            }
        } else {
            selection = try routeMachine(allowProvision: true)
        }
        let machine = selection.id
        let machineName = selection.label ?? Self.vmMachineDisplayName(machine)
        phase("machine", machineLabel, machineStarted, detail: machineName == machine
            ? "\(machine) (\(selection.reason))"
            : "\(machineName) \(machine) (\(selection.reason))")
        // A paused machine is woken here, with one line, rather than by whichever request
        // reaches it first. The status comes from the list routing already read.
        if !selection.created,
           let seconds = try wakeVMIfParked(
               machine: machine,
               knownStatus: selection.status ?? pinnedStatus,
               readStatus: false,
               displayName: machineName,
               client: client
           ) {
            timings.append(("wake", String(localized: "cli.vm.clone.phase.wake", defaultValue: "Wake"), seconds))
        }
        if selection.pick == .onlyRunning {
            cliWriteStderr(String(
                format: String(
                    localized: "cli.vm.clone.onlyRunningMachine",
                    defaultValue: "Using %@ (your only running machine). Use --new for a fresh one."
                ),
                machineName
            ) + "\n")
        }

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
                    remoteDir, machineName, what
                ))
            }
            if Self.vmCloneLooksLikeAuthFailure(cloneStderr) {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.vm.clone.authFailed",
                        defaultValue: "vm clone: %1$@ could not read %2$@ \u{2014} the repository is private or the machine has no access to it. Add a GitHub token with `cmux vm secrets import --gh`, then run this again."
                    ),
                    machineName, spec.cloneURL
                ))
            }
            let detail = cloneStderr.isEmpty ? "" : "\n\(cloneStderr)"
            throw CLIError(message: String(
                format: String(
                    localized: "cli.vm.clone.failed",
                    defaultValue: "vm clone: git failed on %1$@ (exit %2$ld)%3$@"
                ),
                machineName, cloneExit, detail
            ))
        }
        let updated = cloneStdout.contains("cmux-clone=updated")
        // Bound only once the machine holds the checkout, so a failed clone never makes
        // the next one return to a machine without it.
        Self.saveVMRunBinding(workKey: Self.vmRunWorkKey(forDirectory: routingDirectory), machine: machine)
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
        // A machine provisioned for this clone already has the daemon's `workspace-1`
        // with an idle home shell. Name that first workspace for the repository (the
        // get-or-create below then finds it) instead of adding a second one beside it.
        // A warm start's daemon already holds the repository's workspace.
        let adoptedWorkspace = selection.created && selection.pick != .warm
            ? adoptVMCloneInitialWorkspace(machine: machine, name: workspaceName, client: client)
            : nil
        var workspaceParams: [String: Any] = [
            "id": machine,
            "name": workspaceName,
            "reuse": true,
            "focus": focusValue,
        ]
        if !open { workspaceParams["open"] = false }
        let workspaceResponse = try client.sendV2(method: "vm.workspace_new", params: workspaceParams, responseTimeout: 240)
        let remoteWorkspace = (workspaceResponse["remote_workspace_id"] as? String) ?? "?"
        let adopted = adoptedWorkspace.map { $0.workspaceID == remoteWorkspace } ?? false
        // An adopted workspace is new to this clone: its starter shell is replaced by
        // one in the checkout, exactly like a workspace created just now.
        let existingWorkspace = adopted ? false : ((workspaceResponse["existing"] as? Bool) ?? false)
        var starterTerminal = (workspaceResponse["terminal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (adopted ? adoptedWorkspace?.starterTerminal : nil)
        let localWorkspace = (workspaceResponse["workspace_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // A fresh workspace's starter shell begins in the home directory. Replace it with
        // a terminal started in the checkout (a native cwd, so nothing is typed into it
        // and the sidebar shows the checkout); an existing workspace keeps whatever its
        // terminals are doing. Without the checkout's absolute path, or when the new
        // terminal cannot start, the starter is moved with `cd` as before.
        if !existingWorkspace, starterTerminal != nil || adopted {
            let starter = starterTerminal
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
                    if let starter {
                        _ = try? client.sendV2(
                            method: "vm.terminal_close",
                            params: ["id": machine, "terminal_id": starter],
                            responseTimeout: 120
                        )
                    }
                    starterTerminal = terminal
                    replaced = true
                }
            }
            if !replaced, let starter {
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
            detail: "\(workspaceName) \(remoteWorkspace)\(existingWorkspace ? " (existing)" : "")\(adopted ? " (the machine's first workspace)" : "")"
        )

        // 6. Setup: the manifest's commands in a visible "setup" terminal, followed here
        // step by step. A failure stops before the agent and leaves the terminal open.
        // Repository-declared commands run with Cloud Secrets in reach, so only the
        // person's own checkout (`.`) runs them unasked (vmCloneSetupDecision).
        var setupOutcome: VMCloneSetupOutcome?
        var setupSkipReason: VMCloneSetupSkipReason?
        if !setupCommands.isEmpty {
            let shown = setupCommands.map { Self.vmSecretsPrintable($0, limit: 60) }.joined(separator: "; ")
            var decision = Self.vmCloneSetupDecision(
                isOwnCheckout: repoArg == ".",
                updated: updated,
                forceSetup: forceSetup,
                skipSetup: skipSetup,
                interactive: isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1
            )
            if warmRestored != nil, decision == .skip(.existingCheckout) {
                decision = .skip(.warmStart)
            }
            if decision == .prompt {
                decision = Self.vmCloneConfirmSetup(
                    commands: setupCommands,
                    repository: spec.displayName,
                    machineName: machineName
                ) ? .run : .skip(.declined)
            }
            if case .skip(let reason) = decision {
                setupSkipReason = reason
                cliWriteStderr(Self.vmCloneSetupSkippedNote(reason, repository: spec.displayName, shown: shown) + "\n")
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
                        ? Self.vmCloneSetupDoneDetail(steps: outcome.steps.count, terminalID: outcome.terminalID)
                        : String(format: String(localized: "cli.vm.clone.setup.failedDetail", defaultValue: "stopped in terminal %@"), outcome.terminalID)
                )
            }
        }
        let setupFailed = setupOutcome?.failure != nil

        // 6b. Warm start: a snapshot of the machine once setup succeeded, before an agent
        // runs in it, so a later clone that needs a new machine starts from here. Asked for
        // with --save-warm, or by `"warm": true` after the first successful setup of a
        // checkout whose setup was trusted to run. A failed save is a note, never a stop.
        var warmSaved: VMWarmStart?
        let previousWarm = Self.loadVMWarmStarts()[spec.projectKey]
        let autoWarm = Self.vmCloneWarmRequested(cloudJSON: manifestFiles[".cmux/cloud.json"])
            && !updated
            && warmRestored == nil
            && previousWarm == nil
            && !skipSetup
            && (repoArg == "." || forceSetup || setupOutcome != nil)
        if !setupFailed, saveWarm || autoWarm {
            let warmLabel = String(localized: "cli.vm.clone.phase.warmSave", defaultValue: "Warm start")
            let warmStarted = Date()
            do {
                let response = try client.sendV2(
                    method: "vm.snapshot",
                    params: ["id": machine, "name": Self.vmWarmStartSnapshotName(projectKey: spec.projectKey)],
                    responseTimeout: Self.vmCreateResponseTimeoutSeconds
                )
                guard let snapshotID = ((response["snapshot_id"] as? String) ?? (response["id"] as? String)).flatMap({ $0.isEmpty ? nil : $0 }) else {
                    throw CLIError(message: String(localized: "cli.vm.clone.warm.noSnapshotID", defaultValue: "the snapshot returned no id"))
                }
                let saved = VMWarmStart(
                    snapshotID: snapshotID,
                    machine: machine,
                    createdAtUnix: Int(Date().timeIntervalSince1970),
                    name: Self.vmWarmStartSnapshotName(projectKey: spec.projectKey)
                )
                Self.saveVMWarmStart(project: spec.projectKey, saved)
                warmSaved = saved
                // The warm start it replaces is deleted: only the newest is ever restored.
                if let previousWarm, previousWarm.snapshotID != snapshotID,
                   previousWarm.name == Self.vmWarmStartSnapshotName(projectKey: spec.projectKey) {
                    _ = try? client.sendV2(
                        method: "vm.snapshot_delete",
                        params: ["id": previousWarm.machine, "snapshot_id": previousWarm.snapshotID],
                        responseTimeout: 130
                    )
                }
                phase("warm_save", warmLabel, warmStarted, detail: String(
                    format: String(
                        localized: "cli.vm.clone.warm.saved",
                        defaultValue: "saved snapshot %@; a clone that needs a new machine starts from it"
                    ),
                    snapshotID
                ))
            } catch {
                let reason = Self.vmCloneWarmFailureReason((error as? CLIError)?.message ?? String(describing: error))
                cliWriteStderr(String(
                    format: String(
                        localized: "cli.vm.clone.warm.saveFailed",
                        defaultValue: "Could not save a warm start of %1$@ (%2$@). The clone itself is done."
                    ),
                    machineName, reason
                ) + "\n")
            }
        }

        // 7. Agent: `vm agent`'s terminal, landed in the repository's workspace and
        // started in the checkout, once setup succeeded.
        var agentTerminal: String?
        var agentSurface: String?
        if !setupFailed, let agent, let agentArgv {
            warnIfVMAgentNotReady(machine: machine, agent: agent, client: client)
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

        // Scripts read the id-based address from --json; people read the label `vm ls`
        // shows, which `cmux vm open` resolves the same way (when it names one machine).
        let address = "\(machine)/\(remoteWorkspace)"
        let displayAddress = "\(selection.addressLabel ?? machine)/\(remoteWorkspace)"
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
            payload["adopted_initial_workspace"] = adopted
            payload["machine_label"] = orNull(selection.label)
            payload["local_workspace_id"] = orNull(localWorkspace)
            payload["terminal_id"] = orNull(starterTerminal)
            payload["agent"] = orNull(agent)
            payload["agent_terminal_id"] = orNull(agentTerminal)
            payload["open"] = "cmux vm open \(address)"
            payload["timings"] = timingPayload
            payload["missing_secrets"] = missingSecrets
            payload["warm_start"] = orNull(warmPayload)
            payload["warm_saved"] = orNull(warmSaved.map { ["snapshot_id": $0.snapshotID] as [String: Any] })
            payload["setup"] = Self.vmCloneSetupPayload(
                commands: setupCommands,
                skipped: setupSkipReason != nil,
                outcome: setupOutcome,
                skipReason: setupSkipReason
            )
            if let agentSurface { payload["agent_surface_id"] = agentSurface }
            print(jsonString(payload))
            if let setupOutcome, setupFailed {
                throw vmCloneSetupFailure(setupOutcome, machine: selection.addressLabel ?? machine, machineName: machineName, address: displayAddress, repoArg: repoArg)
            }
            return
        }
        cliWriteStderr(summary + "\n")
        if let setupOutcome, setupFailed {
            throw vmCloneSetupFailure(setupOutcome, machine: selection.addressLabel ?? machine, machineName: machineName, address: displayAddress, repoArg: repoArg)
        }
        print(String(
            format: updated
                ? String(localized: "cli.vm.clone.doneUpdated", defaultValue: "Updated %1$@ in %2$@ on %3$@.")
                : String(localized: "cli.vm.clone.doneCloned", defaultValue: "Cloned %1$@ into %2$@ on %3$@."),
            spec.projectKey, remoteDir, machineName
        ))
        print(String(
            format: String(localized: "cli.vm.clone.openAddress", defaultValue: "Open: cmux vm open %@"),
            displayAddress
        ))
        if let agentTerminal, let agent {
            print(String(
                format: String(localized: "cli.vm.clone.agentAddress", defaultValue: "%1$@: cmux vm open %2$@/%3$@"),
                agent, displayAddress, agentTerminal
            ))
        }
    }

    // MARK: - Warm start restore

    /// The first line of a failure, short enough for the one-line fallback note.
    static func vmCloneWarmFailureReason(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return line.count > 160 ? String(line.prefix(159)) + "\u{2026}" : line
    }

    /// Run on a machine restored from a warm start before Cloud Secrets sync: the snapshot
    /// carried its source machine's env file, and this machine's values come from Cloud
    /// Secrets alone (a name removed from the vault since the snapshot must not come back).
    static let vmCloneWarmEnvResetCommand = #"rm -f -- "$HOME/.config/cmux/env""#

    /// Restores `warm` as a new pool machine (the router's own kind of machine, so later
    /// routing can reuse it) and waits until it runs. Returns its id, or why it could not;
    /// nothing here throws, so a bad snapshot never blocks the clone. A snapshot the
    /// backend no longer has is forgotten, so the next clone does not try it again.
    func restoreVMCloneWarmStart(_ warm: VMWarmStart, project: String, client: SocketClient) -> (id: String?, failure: String?) {
        let response: [String: Any]
        do {
            response = try client.sendV2(
                method: "vm.restore",
                params: ["snapshot_id": warm.snapshotID, "idempotency_key": UUID().uuidString.lowercased()],
                responseTimeout: Self.vmCreateResponseTimeoutSeconds
            )
        } catch {
            if let error = error as? CLIError, error.vmBackendCode == "vm_snapshot_not_found" {
                Self.saveVMWarmStart(project: project, nil)
            }
            return (nil, Self.vmCloneWarmFailureReason((error as? CLIError)?.message ?? String(describing: error)))
        }
        guard let id = (response["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return (nil, String(localized: "cli.vm.clone.warm.noMachineID", defaultValue: "the restore returned no machine"))
        }
        try? Self.updateVMRunPool { machines in machines.insert(id) }
        _ = try? client.sendV2(method: "vm.rename", params: ["id": id, "display_name": Self.vmRunPoolLabel], responseTimeout: 60)
        do {
            try waitForVMReady(vmID: id, timeoutSeconds: Self.vmRunCreateWaitSeconds, client: client)
        } catch {
            // A restore can become ready after this timeout. Remove it from the
            // reusable pool and destroy it now so the snapshot's workspace graph
            // and environment cannot leak into a later cold fallback.
            discardVMCloneWarmStart(id: id, client: client)
            let reason = Self.vmCloneWarmFailureReason((error as? CLIError)?.message ?? String(describing: error))
            return (nil, String(
                format: String(localized: "cli.vm.clone.warm.notReady", defaultValue: "%1$@ did not start: %2$@"),
                id, reason
            ))
        }
        do {
            let reset = try client.sendV2(
                method: "vm.exec",
                params: ["id": id, "command": Self.vmCloneWarmEnvResetCommand, "timeout_ms": 30_000],
                responseTimeout: 60
            )
            let exitCode = reset["exit_code"] as? Int ?? -1
            guard exitCode == 0 else {
                discardVMCloneWarmStart(id: id, client: client)
                return (nil, String(
                    localized: "cli.vm.clone.warm.envResetFailed",
                    defaultValue: "the restored machine's environment could not be cleared"
                ))
            }
        } catch {
            discardVMCloneWarmStart(id: id, client: client)
            return (nil, String(
                localized: "cli.vm.clone.warm.envResetFailed",
                defaultValue: "the restored machine's environment could not be cleared"
            ))
        }
        do {
            try resetVMCloneWarmWorkspaces(machine: id, client: client)
        } catch {
            // A restored machine still carrying the source machine's workspace graph
            // is not a safe warm clone. Remove it before falling back to a cold machine;
            // otherwise the old workspaces would remain visible in the pool.
            discardVMCloneWarmStart(id: id, client: client)
            return (nil, Self.vmCloneWarmFailureReason((error as? CLIError)?.message ?? String(describing: error)))
        }
        return (id, nil)
    }

    /// Removes a failed warm restore from the local reuse pool before best-effort
    /// destruction. The provider may finish booting after a readiness timeout, so
    /// deleting the pool entry is required even when destruction is unavailable.
    private func discardVMCloneWarmStart(id: String, client: SocketClient) {
        _ = try? Self.updateVMRunPool { machines in machines.remove(id) }
        _ = try? client.sendV2(
            method: "vm.destroy",
            params: ["id": id],
            responseTimeout: 120
        )
    }

    /// Removes every remote workspace restored from a warm snapshot. The machine id is
    /// newly allocated by `vm.restore`, so this cannot delete a workspace owned by the
    /// source machine or another user machine.
    private func resetVMCloneWarmWorkspaces(machine: String, client: SocketClient) throws {
        guard let catalog = try? client.sendV2(
            method: "vm.tree",
            params: ["id": machine, "refresh": true],
            responseTimeout: 120
        ), let payload = VMRemoteWorkspaceResolver().vmMachinePayload(machine, from: catalog),
              let rawWorkspaces = payload["remote_workspaces"] as? [[String: Any]] else {
            throw CLIError(message: String(
                localized: "cli.vm.clone.warm.workspaceReadFailed",
                defaultValue: "the restored machine's workspaces could not be read"
            ))
        }
        for workspace in rawWorkspaces {
            guard let workspaceID = workspace["id"] as? String, !workspaceID.isEmpty else { continue }
            _ = try client.sendV2(
                method: "vm.workspace_delete",
                params: ["id": machine, "workspace_id": workspaceID],
                responseTimeout: 240
            )
        }
    }

    // MARK: - Setup trust

    /// Why the repository's setup commands did not run.
    enum VMCloneSetupSkipReason: String, Equatable {
        /// `--skip-setup`.
        case flag = "skip_setup"
        /// The checkout already existed and was only updated (no `--setup`).
        case existingCheckout = "existing_checkout"
        /// Another person's repository with no terminal to ask on (no `--setup`).
        case needsConfirmation = "needs_confirmation"
        /// Asked at the prompt and not confirmed.
        case declined = "declined"
        /// The machine was restored from the repository's warm start, which ran it already.
        case warmStart = "warm_start"
    }

    enum VMCloneSetupDecision: Equatable {
        case run
        case prompt
        case skip(VMCloneSetupSkipReason)
    }

    /// Whether a clone runs the repository's `.cmux/cloud.json` setup. The commands run
    /// with the person's Cloud Secrets in reach, so only their own checkout (`.`) runs
    /// them unasked; any other repository asks on a terminal and is skipped without one.
    /// An update of an existing checkout never re-runs setup on its own. `--setup` and
    /// `--skip-setup` decide outright. Pure.
    static func vmCloneSetupDecision(
        isOwnCheckout: Bool,
        updated: Bool,
        forceSetup: Bool,
        skipSetup: Bool,
        interactive: Bool
    ) -> VMCloneSetupDecision {
        if skipSetup { return .skip(.flag) }
        if forceSetup { return .run }
        if updated { return .skip(.existingCheckout) }
        if isOwnCheckout { return .run }
        return interactive ? .prompt : .skip(.needsConfirmation)
    }

    /// `--dry-run`'s `setup` field: `run`, `skip`, or `confirm` (asked, or skipped
    /// without a terminal). An existing checkout is only known once the clone runs.
    static func vmCloneSetupPlanValue(isOwnCheckout: Bool, forceSetup: Bool, skipSetup: Bool) -> String {
        if skipSetup { return "skip" }
        if forceSetup || isOwnCheckout { return "run" }
        return "confirm"
    }

    /// The one-line note for a skipped setup, naming how to run it.
    static func vmCloneSetupSkippedNote(_ reason: VMCloneSetupSkipReason, repository: String, shown: String) -> String {
        switch reason {
        case .flag:
            return String(
                format: String(localized: "cli.vm.clone.setup.skipped", defaultValue: "Setup skipped (--skip-setup): %1$@"),
                shown
            )
        case .existingCheckout:
            return String(
                format: String(
                    localized: "cli.vm.clone.setup.skippedExisting",
                    defaultValue: "Setup skipped: %1$@ was already checked out on the machine. Run again with --setup to run its setup commands (%2$@)."
                ),
                repository, shown
            )
        case .needsConfirmation:
            return String(
                format: String(
                    localized: "cli.vm.clone.setup.skippedUnconfirmed",
                    defaultValue: "Setup skipped: run again with --setup to run the setup commands from %1$@ (%2$@)."
                ),
                repository, shown
            )
        case .declined:
            return String(localized: "cli.vm.clone.setup.skippedDeclined", defaultValue: "Setup skipped.")
        case .warmStart:
            return String(
                format: String(
                    localized: "cli.vm.clone.setup.skippedWarm",
                    defaultValue: "Setup skipped: the warm start of %1$@ already ran it. Run again with --setup to refresh dependencies (%2$@)."
                ),
                repository, shown
            )
        }
    }

    /// The setup phase's detail line. English picks the form here (the CLI formats
    /// with `String(format:)`, which never consults a catalog plural); other languages
    /// carry plural variations on the count (scripts/localization-plurals.json).
    static func vmCloneSetupDoneDetail(steps: Int, terminalID: String) -> String {
        let format = steps == 1
            ? String(localized: "cli.vm.clone.setup.doneDetail.one", defaultValue: "%ld step in terminal %@")
            : String(localized: "cli.vm.clone.setup.doneDetail", defaultValue: "%ld steps in terminal %@")
        return String(format: format, steps, terminalID)
    }

    /// The setup prompt: a lead-in naming where the commands come from, the numbered
    /// commands, and the question, singular or plural by the count (as above).
    static func vmCloneSetupConfirmText(commands: [String], repository: String, machineName: String) -> String {
        var text = String(
            format: String(localized: "cli.vm.clone.setup.confirmLeadIn", defaultValue: "Setup commands from %@:"),
            repository
        ) + "\n"
        for (index, command) in commands.enumerated() {
            text += "  \(index + 1). \(Self.vmSecretsPrintable(command, limit: 200))\n"
        }
        let format = commands.count == 1
            ? String(
                localized: "cli.vm.clone.setup.confirm.one",
                defaultValue: "Run %1$ld setup command from %2$@ on %3$@? It runs with your Cloud Secrets. [y/N] "
            )
            : String(
                localized: "cli.vm.clone.setup.confirm",
                defaultValue: "Run these %1$ld setup commands from %2$@ on %3$@? They run with your Cloud Secrets. [y/N] "
            )
        return text + String(format: format, commands.count, repository, machineName)
    }

    /// Lists the setup commands on stderr and asks once; only `y` or `yes` runs them.
    static func vmCloneConfirmSetup(commands: [String], repository: String, machineName: String) -> Bool {
        cliWriteStderr(vmCloneSetupConfirmText(commands: commands, repository: repository, machineName: machineName))
        guard let answer = readLine(strippingNewline: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return answer == "y" || answer == "yes"
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

        /// Why setup stopped short, with each part kept apart so the final error is
        /// one self-contained sentence per case rather than a clause spliced into another.
        enum Stop: Equatable {
            case exited(step: Int, total: Int, command: String, code: Int)
            case terminalClosed(step: Int, total: Int, command: String)
            case timedOut(step: Int, total: Int, command: String, seconds: TimeInterval)
        }

        let terminalID: String
        var steps: [Step] = []
        /// Why setup stopped, as a clause for the JSON `error` field; nil when every
        /// step exited 0.
        var failure: String?
        var stop: Stop?
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
                outcome.stop = .exited(step: index + 1, total: total, command: label(index), code: code)
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
            if wait.state == .exited {
                clearLive()
                outcome.failure = String(
                    format: String(localized: "cli.vm.clone.setup.exited", defaultValue: "the setup terminal closed during step %1$ld/%2$ld `%3$@`"),
                    current + 1, total, label(current)
                )
                outcome.stop = .terminalClosed(step: current + 1, total: total, command: label(current))
                outcome.exitCode = 1
                return outcome
            }
            if wait.state == .unknown, page.text.isEmpty {
                // No wait method blocked this slice: poll the output at a bounded pace
                // (the deadline below still ends the follow).
                Thread.sleep(forTimeInterval: Self.vmCloneSetupPollInterval())
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
                outcome.stop = .timedOut(step: current + 1, total: total, command: label(current), seconds: Self.vmCloneSetupTimeoutSeconds)
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

    /// What one wait slice learned about the setup terminal's process.
    enum VMCloneSetupTerminalState: Equatable {
        /// The daemon says the process is still running (or the slice timed out on it).
        case running
        /// The daemon says the process exited.
        case exited
        /// Neither wait could run (an older app or daemon, a dropped request): nothing
        /// is known, which is never read as "exited". The caller polls the output.
        case unknown
    }

    struct VMCloneSetupWait: Equatable {
        var matched: Bool
        var screen: String
        var state: VMCloneSetupTerminalState
    }

    /// Seconds between output reads while neither wait method is available.
    /// `CMUX_VM_CLONE_SETUP_POLL_SECONDS` (0 < s <= 2) shortens it for tests against a mock.
    static func vmCloneSetupPollInterval(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        guard let raw = environment["CMUX_VM_CLONE_SETUP_POLL_SECONDS"],
              let parsed = TimeInterval(raw), parsed.isFinite, parsed > 0, parsed <= 2 else { return 2 }
        return parsed
    }

    /// Blocks until the screen shows `pattern` or one slice passes. When the wait cannot
    /// run, blocks on the process instead (`vm.terminal_wait_exit`, same slice); only a
    /// daemon answer of "exited" reports a terminal whose shell is gone.
    func waitForVMCloneSetupStep(machine: String, terminalID: String, pattern: String, client: SocketClient) -> VMCloneSetupWait {
        let slice = Self.vmCloneSetupSliceMs
        if let response = try? client.sendV2(
            method: "vm.terminal_wait",
            params: ["id": machine, "terminal_id": terminalID, "pattern": pattern, "timeout_ms": slice],
            responseTimeout: TimeInterval(slice / 1000 + 60)
        ) {
            return VMCloneSetupWait(
                matched: (response["matched"] as? Bool) == true,
                screen: (response["text"] as? String) ?? "",
                state: (response["exited"] as? Bool) == true ? .exited : .running
            )
        }
        // The screen wait cannot run (the terminal ended, or an older machine): block on
        // the process for the same slice instead, so the follow loop never spins.
        if let response = try? client.sendV2(
            method: "vm.terminal_wait_exit",
            params: ["id": machine, "terminal_id": terminalID, "timeout_ms": slice],
            responseTimeout: TimeInterval(slice / 1000 + 60)
        ) {
            return VMCloneSetupWait(
                matched: false,
                screen: "",
                state: (response["state"] as? String) == "exited" ? .exited : .running
            )
        }
        return VMCloneSetupWait(matched: false, screen: "", state: .unknown)
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
    static func vmCloneSetupPayload(
        commands: [String],
        skipped: Bool,
        outcome: VMCloneSetupOutcome?,
        skipReason: VMCloneSetupSkipReason? = nil
    ) -> [String: Any] {
        let status: String
        if commands.isEmpty {
            status = "none"
        } else if outcome == nil {
            status = skipped ? "skipped" : "none"
        } else {
            status = outcome?.failure == nil ? "done" : "failed"
        }
        var payload: [String: Any] = ["status": status, "commands": commands]
        if let skipReason, outcome == nil, !commands.isEmpty { payload["skip_reason"] = skipReason.rawValue }
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
    func vmCloneSetupFailure(_ outcome: VMCloneSetupOutcome, machine: String, machineName: String, address: String, repoArg: String) -> CLIError {
        let message = [
            Self.vmCloneSetupFailureHeadline(outcome, machineName: machineName),
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

    /// The first line of a failed setup: one whole sentence per way setup stops, with
    /// the step, the command, the exit code and the machine each a placeholder of its own.
    static func vmCloneSetupFailureHeadline(_ outcome: VMCloneSetupOutcome, machineName: String) -> String {
        switch outcome.stop {
        case .exited(let step, let total, let command, let code)?:
            return String(
                format: String(
                    localized: "cli.vm.clone.setup.failed.exit",
                    defaultValue: "vm clone: setup step %1$ld of %2$ld (`%3$@`) exited with code %4$ld on %5$@. The \"setup\" terminal stays open in the checkout."
                ),
                step, total, command, code, machineName
            )
        case .terminalClosed(let step, let total, let command)?:
            return String(
                format: String(
                    localized: "cli.vm.clone.setup.failed.closed",
                    defaultValue: "vm clone: the \"setup\" terminal on %4$@ closed during setup step %1$ld of %2$ld (`%3$@`)."
                ),
                step, total, command, machineName
            )
        case .timedOut(let step, let total, let command, let seconds)?:
            let limit = DateComponentsFormatter.localizedString(
                from: DateComponents(second: Int(seconds)),
                unitsStyle: .full
            ) ?? "\(Int(seconds))s"
            return String(
                format: String(
                    localized: "cli.vm.clone.setup.failed.timedOut",
                    defaultValue: "vm clone: setup step %1$ld of %2$ld (`%3$@`) was still running on %4$@ after %5$@. It was not stopped; the \"setup\" terminal stays open in the checkout."
                ),
                step, total, command, machineName, limit
            )
        case nil:
            return String(
                format: String(
                    localized: "cli.vm.clone.setup.failed.unknown",
                    defaultValue: "vm clone: setup did not finish on %@. The \"setup\" terminal stays open in the checkout."
                ),
                machineName
            )
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
            format: String(localized: "cli.vm.clone.secretsSent", defaultValue: "%ld delivered"),
            sent.count
        ))
    }
}
