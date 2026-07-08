import Darwin
import Foundation

/// `cmux vm onboard` — the stepped onboarding flow over the env-layer
/// primitives. The user never authors a spec: we infer the repo, derive
/// `.cmux/env.yaml` from what the repo already declares (devcontainer, CI
/// workflow, mise, language heuristics), run the layered build with live
/// progress, and end on the payoff: the next open of this environment is
/// instant. Linear prompts + streaming lines by design; onboarding is a flow,
/// not a screen.
extension CMUXCLI {
    /// Shared dispatch for `cmux vm onboard` and `cmux vm env`, hosted here so
    /// the >900-line `cmux.swift` needs exactly one case line for the family.
    func runVMEnvFamilyCommand(
        subcommand: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowId: String?,
        idFormat: CLIIDFormat
    ) throws {
        if subcommand == "onboard" {
            try runVMOnboardCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, windowId: windowId, idFormat: idFormat)
        } else {
            try runVMEnvCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, windowId: windowId, idFormat: idFormat)
        }
    }

    func runVMOnboardCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowId: String?,
        idFormat: CLIIDFormat
    ) throws {
        if jsonOutput {
            throw CLIError(message: "vm onboard is an interactive flow with no JSON output; run it without --json. For machine-readable builds use: cmux vm env build --json")
        }
        let assumeYes = hasFlag(commandArgs, name: "--yes") || hasFlag(commandArgs, name: "-y")
        let specOnly = hasFlag(commandArgs, name: "--spec-only")
        let positional = commandArgs.filter { !$0.hasPrefix("-") }
        let urlArg = positional.first

        let ui = VMOnboardUI(interactive: !assumeYes && isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1)

        ui.header("cmux cloud onboarding")

        // 1. Resolve the repo: explicit URL, or the checkout we're standing in.
        let repo = try vmOnboardResolveRepo(urlArg: urlArg, ui: ui)
        ui.line("repo: \(repo.displayName)\(repo.inferred ? "  (from git remote)" : "")")
        if repo.scanRoot != FileManager.default.currentDirectoryPath, repo.temporaryClone {
            ui.dim("scanning a shallow clone at \(repo.scanRoot)")
        }
        if !ui.confirm("Onboard this repo to a cloud environment?", default: true) {
            ui.dim("stopped. Pass a repo URL: cmux vm onboard <git-url>")
            return
        }

        // 2. Existing spec wins; otherwise derive one.
        let specPath = (repo.scanRoot as NSString).appendingPathComponent(".cmux/env.yaml")
        if FileManager.default.fileExists(atPath: specPath) {
            ui.ok("this repo is already onboarded (.cmux/env.yaml exists)")
        } else {
            ui.step("scanning for environment sources...")
            let derivation = VMOnboardDeriver.derive(
                repoRoot: repo.scanRoot,
                cloneURL: repo.cloneURL,
                repoName: repo.name
            )
            for source in derivation.sources {
                ui.ok("\(source.path)  →  \(source.summary)")
            }
            for skipped in derivation.untranslated {
                ui.dim("found \(skipped) — not auto-translated yet")
            }
            if derivation.sources.isEmpty {
                ui.dim("no environment sources recognized; starting from a bare clone spec.")
                ui.dim("your agent can repair it: it gets the failing step + logs from `cmux vm env build --json`.")
            }
            let yaml = VMOnboardDeriver.renderSpecYAML(
                name: repo.name,
                derivation: derivation,
                derivedFrom: derivation.sources.map(\.path)
            )
            ui.line("")
            ui.line("derived \(derivation.steps.count)-step environment spec:")
            ui.preview(yaml)
            let choice = ui.choose("Write .cmux/env.yaml and continue?", options: ["y", "n", "e"], help: "y = write, n = stop, e = write then open $EDITOR", default: "y")
            if choice == "n" {
                ui.dim("stopped. Nothing written.")
                return
            }
            try FileManager.default.createDirectory(
                atPath: (repo.scanRoot as NSString).appendingPathComponent(".cmux"),
                withIntermediateDirectories: true
            )
            try yaml.write(toFile: specPath, atomically: true, encoding: .utf8)
            ui.ok("wrote \(specPath)")
            if choice == "e" {
                vmOnboardOpenEditor(path: specPath, ui: ui)
            }
        }

        if specOnly {
            ui.line("")
            ui.line("Spec ready. Build it with: cmux vm env build --spec \(specPath)")
            return
        }

        // 3. Build the layered environment with the standard streaming output.
        ui.line("")
        ui.step("building the environment in a cloud VM (the first build is the slow one; every later boot is ~1s)...")
        do {
            try runVMEnvCommand(
                commandArgs: ["build", "--spec", specPath],
                client: client,
                jsonOutput: false,
                windowId: windowId,
                idFormat: idFormat
            )
        } catch {
            ui.line("")
            ui.fail("the build stopped before verify passed.")
            ui.line("Fix loop (or hand it to your agent — see the cmux-cloud-env skill):")
            ui.line("  1. cmux vm env build --spec \(specPath) --json   # failing step + log tail")
            ui.line("  2. edit only the failing step in .cmux/env.yaml  # earlier layers stay cached")
            ui.line("  3. re-run — only the changed layers execute")
            throw error
        }

        // 4. The payoff.
        ui.line("")
        ui.ok("environment ready and cached for your team.")
        ui.line("From now on `cmux vm env up` boots \(repo.name) ready-to-work in about a second,")
        ui.line("from this Mac or your phone. Commit .cmux/env.yaml so teammates get the same.")
        if repo.temporaryClone {
            ui.dim("spec lives in the scan clone: \(specPath) — copy it into the repo and commit.")
        }
        if ui.confirm("Open the environment now?", default: true) {
            try runVMEnvCommand(
                commandArgs: ["up", "--spec", specPath],
                client: client,
                jsonOutput: false,
                windowId: windowId,
                idFormat: idFormat
            )
        } else {
            ui.line("Later: cmux vm env up")
        }
    }

    // MARK: - Repo resolution

    struct VMOnboardRepo {
        let name: String
        let cloneURL: String
        let displayName: String
        /// Directory scanned for environment sources (local checkout or shallow clone).
        let scanRoot: String
        let inferred: Bool
        let temporaryClone: Bool
    }

    private func vmOnboardResolveRepo(urlArg: String?, ui: VMOnboardUI) throws -> VMOnboardRepo {
        if let urlArg {
            // Normalize scp-style ssh remotes to https up front so the spec's
            // clone step never needs an SSH identity inside the VM.
            let cloneURL = VMOnboardDeriver.normalizedCloneURL(urlArg)
            let name = VMOnboardDeriver.repoName(fromURL: cloneURL)
            try Self.vmOnboardValidateRepoIdentity(cloneURL: cloneURL, name: name)
            // Standing inside a checkout of the same repo (same host + owner +
            // repo, not just the same basename)? Scan it directly.
            if let localRoot = Self.vmOnboardGitToplevel(),
               let remote = Self.vmOnboardGitRemoteURL(),
               VMOnboardDeriver.canonicalRepoKey(remote) == VMOnboardDeriver.canonicalRepoKey(cloneURL) {
                return VMOnboardRepo(
                    name: name, cloneURL: cloneURL, displayName: cloneURL,
                    scanRoot: localRoot, inferred: false, temporaryClone: false
                )
            }
            ui.step("fetching \(cloneURL) for scanning (shallow)...")
            let scanRoot = try Self.vmOnboardShallowClone(url: cloneURL, name: name)
            return VMOnboardRepo(
                name: name, cloneURL: cloneURL, displayName: cloneURL,
                scanRoot: scanRoot, inferred: false, temporaryClone: true
            )
        }
        guard let root = Self.vmOnboardGitToplevel(), let remote = Self.vmOnboardGitRemoteURL() else {
            throw CLIError(message: """
                Not inside a git repo with an `origin` remote.

                Run from a checkout, or pass the repo directly:
                  cmux vm onboard https://github.com/OWNER/REPO
                """)
        }
        let cloneURL = VMOnboardDeriver.normalizedCloneURL(remote)
        let name = VMOnboardDeriver.repoName(fromURL: remote)
        try Self.vmOnboardValidateRepoIdentity(cloneURL: cloneURL, name: name)
        return VMOnboardRepo(
            name: name,
            cloneURL: cloneURL,
            displayName: cloneURL,
            scanRoot: root,
            inferred: true,
            temporaryClone: false
        )
    }

    /// The clone URL and repo name are interpolated into generated spec `run:`
    /// lines that execute in the VM, so reject anything shell could reinterpret
    /// before it reaches the spec.
    private static func vmOnboardValidateRepoIdentity(cloneURL: String, name: String) throws {
        guard VMOnboardDeriver.isRemoteCloneURL(cloneURL) else {
            throw CLIError(message: """
                The VM clones over the network, so a local path or file:// origin won't work: \(cloneURL)
                Pass the repo's hosted URL: cmux vm onboard https://github.com/OWNER/REPO
                """)
        }
        guard VMOnboardDeriver.isShellSafeCloneURL(cloneURL) else {
            throw CLIError(message: "Repo URL contains characters that are not valid in a git URL: \(cloneURL)")
        }
        guard VMOnboardDeriver.isShellSafeRepoName(name) else {
            throw CLIError(message: "Could not derive a safe checkout directory name from: \(cloneURL)")
        }
    }

    private static func vmOnboardGitToplevel() -> String? {
        vmOnboardRunGit(["rev-parse", "--show-toplevel"])
    }

    private static func vmOnboardGitRemoteURL() -> String? {
        vmOnboardRunGit(["remote", "get-url", "origin"])
    }

    private static func vmOnboardRunGit(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    private static func vmOnboardShallowClone(url: String, name: String) throws -> String {
        let dir = NSTemporaryDirectory() + "cmux-onboard-\(name)-\(ProcessInfo.processInfo.processIdentifier)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--depth", "1", url, dir]
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CLIError(message: "Could not clone \(url) for scanning:\n\(err)")
        }
        return dir
    }

    private func vmOnboardOpenEditor(path: String, ui: VMOnboardUI) {
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // git's GIT_EDITOR pattern: $EDITOR stays shell-expandable (supports
        // "code -w"), while the path is passed as a positional argument so a
        // path with spaces or metacharacters can never become shell code.
        process.arguments = ["-c", "\(editor) \"$@\"", "sh", path]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            ui.dim("could not launch $EDITOR; edit \(path) manually.")
        }
    }
}

/// Minimal linear-flow renderer: colored markers when stdout is a TTY, plain
/// text otherwise, prompts only in interactive mode (non-interactive accepts
/// defaults so `--yes` and piped runs never hang).
struct VMOnboardUI {
    let interactive: Bool
    private let color: Bool

    init(interactive: Bool) {
        self.interactive = interactive
        self.color = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    private func paint(_ text: String, _ code: String) -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    func header(_ text: String) { print(paint("◆ \(text)", "1;36")) }
    func step(_ text: String) { print(paint("◆", "36") + " \(text)") }
    func ok(_ text: String) { print("  " + paint("✓", "32") + " \(text)") }
    func fail(_ text: String) { print("  " + paint("✗", "31") + " \(text)") }
    func line(_ text: String) { print(text.isEmpty ? "" : "  \(text)") }
    func dim(_ text: String) { print("  " + paint(text, "2")) }

    func preview(_ body: String) {
        for line in body.components(separatedBy: "\n") {
            print("    " + paint(line, "2"))
        }
    }

    func confirm(_ question: String, default defaultAnswer: Bool) -> Bool {
        guard interactive else { return defaultAnswer }
        let hint = defaultAnswer ? "[Y/n]" : "[y/N]"
        print(paint("? ", "33") + question + " " + hint + " ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return defaultAnswer }
        if answer.isEmpty { return defaultAnswer }
        return answer.hasPrefix("y")
    }

    func choose(_ question: String, options: [String], help: String, default defaultOption: String) -> String {
        guard interactive else { return defaultOption }
        print(paint("? ", "33") + question + " [\(options.joined(separator: "/"))] " + paint("(\(help))", "2") + " ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), !answer.isEmpty else {
            return defaultOption
        }
        return options.contains(answer) ? answer : defaultOption
    }
}
