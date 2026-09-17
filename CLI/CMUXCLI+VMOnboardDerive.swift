import Foundation

/// Derivation ladder for `cmux vm onboard`: synthesize a `.cmux/env.yaml` from
/// what a repo already declares about its own environment, so the user never
/// authors a spec by hand. Sources are tried in confidence order:
///
///   1. devcontainer.json  — the repo's stated dev environment
///   2. GitHub workflow    — CI already builds this repo in a clean Linux box,
///                           and env specs are deliberately GHA-shaped
///   3. mise.toml / .tool-versions — declared toolchains
///   4. language heuristics — lockfiles/build files imply standard steps
///
/// Everything here is pure (paths in, spec out) so it unit-tests without a VM.
struct VMOnboardDerivation {
    struct Source {
        let path: String
        let kind: Kind
        let summary: String

        enum Kind: String {
            case existingSpec = "env.yaml"
            case devcontainer = "devcontainer"
            case githubWorkflow = "workflow"
            case mise = "mise"
            case heuristic = "heuristic"
        }
    }

    let sources: [Source]
    let steps: [VMEnvSpec.Step]
    let verify: [String]
    /// Sources we saw but could not translate (e.g. flake.nix); surfaced in the
    /// TUI so the user knows what was skipped rather than silently ignored.
    let untranslated: [String]
}

enum VMOnboardDeriver {
    typealias Source = VMOnboardDerivation.Source

    // MARK: - Repo scan

    /// Derive an environment for the repo rooted at `repoRoot`, to be cloned in
    /// the VM as `cloneURL` (checkout dir inferred from the URL's last path
    /// component). Always yields at least the clone step; a repo with no
    /// recognizable signal comes back with empty `sources`, which the TUI
    /// surfaces as a bare clone spec.
    static func derive(repoRoot: String, cloneURL: String, repoName: String) -> VMOnboardDerivation {
        var sources: [Source] = []
        var steps: [VMEnvSpec.Step] = []
        var verify: [String] = []
        var untranslated: [String] = []
        let fm = FileManager.default

        func exists(_ relative: String) -> Bool {
            fm.fileExists(atPath: (repoRoot as NSString).appendingPathComponent(relative))
        }
        func read(_ relative: String) -> String? {
            let path = (repoRoot as NSString).appendingPathComponent(relative)
            guard let data = fm.contents(atPath: path) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        // Every derived spec starts by cloning the repo; later steps run inside it.
        steps.append(VMEnvSpec.Step(
            name: "clone \(repoName)",
            run: "test -d \(repoName) || git clone --recurse-submodules \(cloneURL) \(repoName)",
            timeoutMinutes: 20
        ))

        // 1. devcontainer.json — fall through to the root variant when the
        // nested file exists but yields nothing (empty, invalid, no commands).
        for candidate in [".devcontainer/devcontainer.json", ".devcontainer.json"] {
            guard let text = read(candidate) else { continue }
            let result = deriveFromDevcontainer(text, repoName: repoName)
            if !result.steps.isEmpty {
                sources.append(Source(path: candidate, kind: .devcontainer, summary: result.summary))
                steps.append(contentsOf: result.steps)
                break
            }
        }

        // 2. GitHub workflows: pick the best build/test job.
        var workflowInstalledToolchains = false
        if let workflowDir = listDir(repoRoot, ".github/workflows") {
            var best: (score: Int, path: String, result: WorkflowDerivation)?
            for file in workflowDir where file.hasSuffix(".yml") || file.hasSuffix(".yaml") {
                let relative = ".github/workflows/\(file)"
                guard let text = read(relative) else { continue }
                guard let result = deriveFromWorkflow(text, repoName: repoName) else { continue }
                let score = workflowScore(fileName: file, jobName: result.jobName, stepCount: result.steps.count)
                if best == nil || score > best!.score {
                    best = (score, relative, result)
                }
            }
            if let best {
                sources.append(Source(
                    path: best.path,
                    kind: .githubWorkflow,
                    summary: "job `\(best.result.jobName)` (\(best.result.steps.count) steps)"
                ))
                steps.append(contentsOf: best.result.steps)
                // Same predicate the final ordering uses: a project command
                // that merely mentions "mise install" in a log line must not
                // count as toolchain setup.
                workflowInstalledToolchains = best.result.steps.contains { isToolchainInstallStep($0) }
            }
        }

        // 3. mise / .tool-versions — skipped only when the workflow's steps
        // actually installed toolchains (a workflow of plain run steps, e.g.
        // CI on a preinstalled runner, still needs the declared toolchains).
        // Like devcontainer above, fall through to the next candidate when a
        // file exists but yields nothing.
        if !workflowInstalledToolchains {
            var miseDerived = false
            for (path, text) in [("mise.toml", read("mise.toml")), (".mise.toml", read(".mise.toml"))] {
                guard let text, let step = deriveFromMise(text) else { continue }
                sources.append(Source(path: path, kind: .mise, summary: "declared toolchains"))
                steps.append(step)
                miseDerived = true
                break
            }
            if !miseDerived, let text = read(".tool-versions") {
                if let step = deriveFromToolVersions(text) {
                    sources.append(Source(path: ".tool-versions", kind: .mise, summary: "declared toolchains"))
                    steps.append(step)
                }
            }
        }

        // 4. Language heuristics — only when nothing above produced project steps.
        if sources.isEmpty {
            let heuristics = deriveFromHeuristics(exists: exists, repoName: repoName)
            if let heuristics {
                sources.append(Source(path: heuristics.marker, kind: .heuristic, summary: heuristics.summary))
                steps.append(contentsOf: heuristics.steps)
                verify.append(contentsOf: heuristics.verify)
            }
        }

        // Note recognized-but-untranslated environment declarations.
        for (marker, label) in [("flake.nix", "flake.nix (nix)"), ("shell.nix", "shell.nix (nix)"), ("Dockerfile", "Dockerfile")] {
            if exists(marker) { untranslated.append(label) }
        }

        if verify.isEmpty {
            verify.append("test -d \(repoName)")
        }
        // Layers execute in order, so toolchain installs must precede project
        // commands regardless of which source contributed them (a devcontainer
        // postCreateCommand must not run before the workflow's setup steps).
        // Stable partition: clone first, then toolchains, then project steps.
        let clone = steps[0]
        let rest = steps.dropFirst()
        let ordered = [clone]
            + rest.filter { isToolchainInstallStep($0) }
            + rest.filter { !isToolchainInstallStep($0) }
        return VMOnboardDerivation(sources: sources, steps: ordered, verify: verify, untranslated: untranslated)
    }

    /// A step whose only effect is installing toolchains (every command line is
    /// a `mise use -g`/`mise install`, ignoring `cd` prefixes).
    private static func isToolchainInstallStep(_ step: VMEnvSpec.Step) -> Bool {
        let commands = step.run.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("cd ") }
        guard !commands.isEmpty else { return false }
        return commands.allSatisfy { $0.hasPrefix("mise use -g") || $0.hasPrefix("mise install") }
    }

    private static func listDir(_ root: String, _ relative: String) -> [String]? {
        let path = (root as NSString).appendingPathComponent(relative)
        return try? FileManager.default.contentsOfDirectory(atPath: path).sorted()
    }

    // MARK: - devcontainer.json

    private static func deriveFromDevcontainer(_ text: String, repoName: String) -> (steps: [VMEnvSpec.Step], summary: String) {
        guard let obj = parseJSONC(text) else { return ([], "") }
        var steps: [VMEnvSpec.Step] = []
        var parts: [String] = []
        // Features map to toolchain installs where a mise equivalent exists.
        if let features = obj["features"] as? [String: Any] {
            var tools: [String] = []
            for key in features.keys.sorted() {
                if let tool = miseToolForDevcontainerFeature(key, options: features[key]) {
                    tools.append(tool)
                }
            }
            if !tools.isEmpty {
                steps.append(VMEnvSpec.Step(
                    name: "toolchains (devcontainer features)",
                    run: tools.map { "mise use -g \($0)" }.joined(separator: "\n"),
                    timeoutMinutes: nil
                ))
                parts.append("\(tools.count) feature(s)")
            }
        }
        for key in ["onCreateCommand", "postCreateCommand"] {
            if let command = devcontainerCommandString(obj[key]) {
                steps.append(VMEnvSpec.Step(
                    name: key,
                    run: "cd \(repoName)\n\(command)",
                    timeoutMinutes: nil
                ))
                parts.append(key)
            }
        }
        return (steps, parts.joined(separator: ", "))
    }

    private static func devcontainerCommandString(_ raw: Any?) -> String? {
        if let command = raw as? String, !command.trimmingCharacters(in: .whitespaces).isEmpty {
            return command
        }
        if let list = raw as? [String], !list.isEmpty {
            return list.joined(separator: " ")
        }
        if let map = raw as? [String: Any] {
            let commands = map.keys.sorted().compactMap { devcontainerCommandString(map[$0]) }
            return commands.isEmpty ? nil : commands.joined(separator: "\n")
        }
        return nil
    }

    private static func miseToolForDevcontainerFeature(_ feature: String, options: Any?) -> String? {
        let version = ((options as? [String: Any])?["version"] as? String).flatMap {
            $0 == "latest" || $0 == "lts" || $0.isEmpty ? nil : $0
        }
        let suffix = version.map { "@\($0)" } ?? ""
        let lower = feature.lowercased()
        if lower.contains("features/node") { return "node\(suffix)" }
        if lower.contains("features/go") { return "go\(suffix)" }
        if lower.contains("features/rust") { return "rust\(suffix)" }
        if lower.contains("features/python") { return "python\(suffix)" }
        if lower.contains("features/java") { return "java\(suffix)" }
        if lower.contains("features/ruby") { return "ruby\(suffix)" }
        return nil
    }

    /// devcontainer.json is JSONC: strip // and /* */ comments plus trailing
    /// commas, then parse strictly.
    static func parseJSONC(_ text: String) -> [String: Any]? {
        var out = ""
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if inString {
                out.append(char)
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                index = text.index(after: index)
                continue
            }
            if char == "\"" {
                inString = true
                out.append(char)
                index = text.index(after: index)
                continue
            }
            if char == "/", text.index(after: index) < text.endIndex {
                let next = text[text.index(after: index)]
                if next == "/" {
                    while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
                    continue
                }
                if next == "*" {
                    index = text.index(index, offsetBy: 2)
                    while index < text.endIndex {
                        if text[index] == "*", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "/" {
                            index = text.index(index, offsetBy: 2)
                            break
                        }
                        index = text.index(after: index)
                    }
                    continue
                }
            }
            out.append(char)
            index = text.index(after: index)
        }
        // Trailing commas before } or ]
        let cleaned = out.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        guard let data = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    // MARK: - mise / .tool-versions

    static func deriveFromMise(_ text: String) -> VMEnvSpec.Step? {
        var inTools = false
        var tools: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inTools = line == "[tools]"
                continue
            }
            guard inTools, let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let tool = String(line[..<eq]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            var version = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            version = version.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !tool.isEmpty else { continue }
            tools.append(version.isEmpty || version == "latest" ? tool : "\(tool)@\(version)")
        }
        guard !tools.isEmpty else { return nil }
        return VMEnvSpec.Step(
            name: "toolchains (mise)",
            run: tools.map { "mise use -g \($0)" }.joined(separator: "\n"),
            timeoutMinutes: nil
        )
    }

    static func deriveFromToolVersions(_ text: String) -> VMEnvSpec.Step? {
        var tools: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            tools.append("\(parts[0])@\(parts[1])")
        }
        guard !tools.isEmpty else { return nil }
        return VMEnvSpec.Step(
            name: "toolchains (.tool-versions)",
            run: tools.map { "mise use -g \($0)" }.joined(separator: "\n"),
            timeoutMinutes: nil
        )
    }

    // MARK: - Heuristics

    private static func deriveFromHeuristics(
        exists: (String) -> Bool,
        repoName: String
    ) -> (marker: String, summary: String, steps: [VMEnvSpec.Step], verify: [String])? {
        if exists("bun.lock") || exists("bun.lockb") {
            // Verify mirrors the install command: re-running is a cheap no-op
            // when the layer worked, and a stricter --frozen-lockfile check
            // could fail even after a successful install (stale lockfile).
            return ("bun.lock", "bun project", [
                VMEnvSpec.Step(name: "install dependencies", run: "cd \(repoName)\nbun install", timeoutMinutes: nil),
            ], ["cd \(repoName) && bun install"])
        }
        if exists("package-lock.json") || exists("package.json") {
            return ("package.json", "node project", [
                VMEnvSpec.Step(name: "install dependencies", run: "cd \(repoName)\nnpm install", timeoutMinutes: nil),
            ], ["cd \(repoName) && node --version"])
        }
        if exists("Cargo.toml") {
            return ("Cargo.toml", "rust project", [
                VMEnvSpec.Step(name: "rust toolchain", run: "mise use -g rust", timeoutMinutes: nil),
                VMEnvSpec.Step(name: "warm build", run: "cd \(repoName)\ncargo build", timeoutMinutes: 45),
            ], ["cd \(repoName) && cargo check"])
        }
        if exists("build.zig") {
            return ("build.zig", "zig project", [
                VMEnvSpec.Step(name: "zig toolchain", run: "mise use -g zig", timeoutMinutes: nil),
                VMEnvSpec.Step(name: "warm build", run: "cd \(repoName)\nzig build", timeoutMinutes: 45),
            ], ["cd \(repoName) && zig build --help >/dev/null"])
        }
        if exists("go.mod") {
            return ("go.mod", "go project", [
                VMEnvSpec.Step(name: "go toolchain", run: "mise use -g go", timeoutMinutes: nil),
                VMEnvSpec.Step(name: "warm build", run: "cd \(repoName)\ngo build ./...", timeoutMinutes: 30),
            ], ["cd \(repoName) && go build ./..."])
        }
        if exists("pyproject.toml") || exists("requirements.txt") {
            return ("pyproject.toml", "python project", [
                VMEnvSpec.Step(
                    name: "install dependencies",
                    run: "cd \(repoName)\nif [ -f pyproject.toml ]; then pip install -e . || true; fi\nif [ -f requirements.txt ]; then pip install -r requirements.txt; fi",
                    timeoutMinutes: nil
                ),
            ], ["cd \(repoName) && python3 --version"])
        }
        return nil
    }

    // MARK: - Rendering

    /// Render a derivation to `.cmux/env.yaml` text using the strict subset the
    /// spec parser accepts (block scalars for multi-line runs).
    static func renderSpecYAML(name: String, derivation: VMOnboardDerivation, derivedFrom: [String]) -> String {
        var out = "# Generated by `cmux vm onboard`"
        if !derivedFrom.isEmpty {
            out += " from: " + derivedFrom.joined(separator: ", ")
        }
        out += "\n# Each step is a cached snapshot layer; edit a step and only it (and later\n"
        out += "# layers) re-run on the next `cmux vm env build`.\n"
        out += "version: 1\n"
        out += "name: \(name)\n"
        out += "steps:\n"
        for step in derivation.steps {
            out += renderStep(name: step.name, run: step.run, timeoutMinutes: step.timeoutMinutes)
        }
        if !derivation.verify.isEmpty {
            out += "verify:\n"
            for run in derivation.verify {
                out += renderStep(name: nil, run: run, timeoutMinutes: nil)
            }
        }
        return out
    }

    private static func renderStep(name: String?, run: String, timeoutMinutes: Int?) -> String {
        var out = ""
        if let name {
            out += "  - name: \(name)\n"
            out += runLine(run, firstKeyLine: false)
        } else {
            out += runLine(run, firstKeyLine: true)
        }
        if let timeoutMinutes {
            out += "    timeoutMinutes: \(timeoutMinutes)\n"
        }
        return out
    }

    private static func runLine(_ run: String, firstKeyLine: Bool) -> String {
        let prefix = firstKeyLine ? "  - run:" : "    run:"
        if run.contains("\n") {
            var out = "\(prefix) |\n"
            for line in run.components(separatedBy: "\n") {
                out += line.isEmpty ? "\n" : "      \(line)\n"
            }
            return out
        }
        return "\(prefix) \(run)\n"
    }
}
