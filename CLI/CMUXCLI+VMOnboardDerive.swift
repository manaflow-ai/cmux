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

    // MARK: - Repo naming

    static func repoName(fromURL url: String) -> String {
        var last = url.split(separator: "/").last.map(String.init) ?? url
        if let colon = last.lastIndex(of: ":") {
            // scp-style git@host:repo(.git) with no slash after the colon
            last = String(last[last.index(after: colon)...])
        }
        if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
        return last.isEmpty ? "repo" : last
    }

    /// Rewrite scp-style ssh remotes to https so the VM can clone public repos
    /// without the user's SSH identity. Private-repo auth is out of scope for
    /// the prototype; the clone step fails visibly and the spec is editable.
    static func normalizedCloneURL(_ url: String) -> String {
        guard url.hasPrefix("git@"), !url.contains("://"), let colon = url.firstIndex(of: ":") else { return url }
        let host = String(url[url.index(url.startIndex, offsetBy: 4)..<colon])
        var path = String(url[url.index(after: colon)...])
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        return "https://\(host)/\(path)"
    }

    // MARK: - Repo scan

    /// Derive an environment for the repo rooted at `repoRoot`, to be cloned in
    /// the VM as `cloneURL` (checkout dir inferred from the URL's last path
    /// component). Returns nil only when the directory has no recognizable
    /// signal at all.
    static func derive(repoRoot: String, cloneURL: String, repoName: String) -> VMOnboardDerivation? {
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

        // 1. devcontainer.json
        for candidate in [".devcontainer/devcontainer.json", ".devcontainer.json"] {
            guard let text = read(candidate) else { continue }
            let result = deriveFromDevcontainer(text, repoName: repoName)
            if !result.steps.isEmpty {
                sources.append(Source(path: candidate, kind: .devcontainer, summary: result.summary))
                steps.append(contentsOf: result.steps)
            }
            break
        }

        // 2. GitHub workflows: pick the best build/test job.
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
            }
        }

        // 3. mise / .tool-versions (skip if a workflow already installed toolchains).
        let workflowDerived = sources.contains { $0.kind == .githubWorkflow }
        if !workflowDerived {
            if let text = read("mise.toml") ?? read(".mise.toml") {
                if let step = deriveFromMise(text) {
                    sources.append(Source(path: "mise.toml", kind: .mise, summary: "declared toolchains"))
                    steps.append(step)
                }
            } else if let text = read(".tool-versions") {
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
        guard !sources.isEmpty || steps.count > 1 else {
            // Only the clone step and no signal: still useful, but flag as bare.
            return VMOnboardDerivation(sources: [], steps: steps, verify: verify, untranslated: untranslated)
        }
        return VMOnboardDerivation(sources: sources, steps: steps, verify: verify, untranslated: untranslated)
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

    // MARK: - GitHub workflow

    struct WorkflowDerivation {
        let jobName: String
        let steps: [VMEnvSpec.Step]
    }

    /// Line-based extraction of one job's steps from a GitHub workflow. This is
    /// intentionally not a YAML parser: workflows are conventionally formatted,
    /// and we only need `jobs.<job>.steps[].{name,uses,run,with.*version*}`.
    static func deriveFromWorkflow(_ text: String, repoName: String) -> WorkflowDerivation? {
        let jobs = extractWorkflowJobs(text)
        guard !jobs.isEmpty else { return nil }
        var best: (score: Int, name: String, steps: [VMEnvSpec.Step])?
        for job in jobs {
            var derived: [VMEnvSpec.Step] = []
            for step in job.steps {
                if let uses = step.uses {
                    if let translated = translateWorkflowAction(uses: uses, with: step.with) {
                        derived.append(translated)
                    }
                    continue
                }
                guard var run = step.run, !run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if isCIOnlyRun(run) { continue }
                // CI checks out into the workspace root; our clone step puts the
                // repo in ~/<repoName>, so project commands need the cd.
                run = "cd \(repoName)\n" + run
                derived.append(VMEnvSpec.Step(name: step.name ?? "run", run: run, timeoutMinutes: nil))
            }
            guard !derived.isEmpty else { continue }
            let score = workflowScore(fileName: "", jobName: job.name, stepCount: derived.count)
            if best == nil || score > best!.score {
                best = (score, job.name, derived)
            }
        }
        guard let best else { return nil }
        return WorkflowDerivation(jobName: best.name, steps: best.steps)
    }

    private struct WorkflowJob {
        let name: String
        var steps: [WorkflowStep]
        var runsOn: String?
    }

    private struct WorkflowStep {
        var name: String?
        var uses: String?
        var run: String?
        var with: [String: String] = [:]
    }

    private static func extractWorkflowJobs(_ text: String) -> [WorkflowJob] {
        let lines = text.components(separatedBy: "\n")
        var jobs: [WorkflowJob] = []
        var index = 0
        // Find top-level `jobs:`
        while index < lines.count, !lines[index].hasPrefix("jobs:") { index += 1 }
        guard index < lines.count else { return [] }
        index += 1
        while index < lines.count {
            let line = lines[index]
            let indent = leadingSpaces(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { index += 1; continue }
            if indent == 0 { break } // next top-level key
            if indent == 2, trimmed.hasSuffix(":"), !trimmed.hasPrefix("-") {
                var job = WorkflowJob(name: String(trimmed.dropLast()), steps: [], runsOn: nil)
                index += 1
                // Scan the job body
                while index < lines.count {
                    let bodyLine = lines[index]
                    let bodyIndent = leadingSpaces(bodyLine)
                    let bodyTrimmed = bodyLine.trimmingCharacters(in: .whitespaces)
                    if bodyTrimmed.isEmpty || bodyTrimmed.hasPrefix("#") { index += 1; continue }
                    if bodyIndent <= 2 { break }
                    if bodyTrimmed.hasPrefix("runs-on:") {
                        job.runsOn = String(bodyTrimmed.dropFirst("runs-on:".count)).trimmingCharacters(in: .whitespaces)
                        index += 1
                        continue
                    }
                    if bodyTrimmed == "steps:" {
                        index += 1
                        job.steps = extractWorkflowSteps(lines, index: &index, minIndent: bodyIndent)
                        continue
                    }
                    index += 1
                }
                // Only Linux jobs translate to a Linux VM.
                let runsOn = job.runsOn?.lowercased() ?? ""
                if runsOn.isEmpty || runsOn.contains("ubuntu") || runsOn.contains("linux") {
                    jobs.append(job)
                }
                continue
            }
            index += 1
        }
        return jobs
    }

    private static func extractWorkflowSteps(_ lines: [String], index: inout Int, minIndent: Int) -> [WorkflowStep] {
        var steps: [WorkflowStep] = []
        var current: WorkflowStep?
        var itemIndent: Int?
        while index < lines.count {
            let line = lines[index]
            let indent = leadingSpaces(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { index += 1; continue }
            if indent <= minIndent { break }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                if let current { steps.append(current) }
                current = WorkflowStep()
                itemIndent = indent
                let rest = String(trimmed.dropFirst(2))
                index += 1
                if !rest.isEmpty {
                    consumeWorkflowStepEntry(rest, lines: lines, index: &index, keyIndent: indent + 2, into: &current!)
                }
                continue
            }
            guard var step = current, let itemIndent, indent >= itemIndent + 2 else { index += 1; continue }
            index += 1
            consumeWorkflowStepEntry(trimmed, lines: lines, index: &index, keyIndent: itemIndent + 2, into: &step)
            current = step
        }
        if let current { steps.append(current) }
        return steps
    }

    private static func consumeWorkflowStepEntry(
        _ entry: String,
        lines: [String],
        index: inout Int,
        keyIndent: Int,
        into step: inout WorkflowStep
    ) {
        guard let colon = entry.firstIndex(of: ":") else { return }
        let key = String(entry[..<colon]).trimmingCharacters(in: .whitespaces)
        var value = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if key == "run", value == "|" || value == "|-" || value == ">" || value == ">-" {
            var collected: [String] = []
            var contentIndent: Int?
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { collected.append(""); index += 1; continue }
                let indent = leadingSpaces(line)
                if indent <= keyIndent { break }
                let effective = contentIndent ?? indent
                contentIndent = effective
                collected.append(String(line.dropFirst(min(effective, indent))))
                index += 1
            }
            while collected.last?.isEmpty == true { collected.removeLast() }
            step.run = collected.joined(separator: "\n")
            return
        }
        value = stripYAMLScalarQuotes(value)
        switch key {
        case "name": step.name = value
        case "uses": step.uses = value
        case "run": step.run = value
        case "with":
            // Collect simple `key: value` lines under with:
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { index += 1; continue }
                let indent = leadingSpaces(line)
                if indent <= keyIndent { break }
                if let colon = trimmed.firstIndex(of: ":") {
                    let withKey = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                    let withValue = stripYAMLScalarQuotes(String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                    step.with[withKey] = withValue
                }
                index += 1
            }
        default:
            break
        }
    }

    private static func stripYAMLScalarQuotes(_ value: String) -> String {
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Map well-known setup actions to toolchain installs; drop CI plumbing.
    private static func translateWorkflowAction(uses: String, with: [String: String]) -> VMEnvSpec.Step? {
        let action = uses.lowercased()
        func version(_ keys: String...) -> String {
            for key in keys {
                if let value = with[key], !value.isEmpty, !value.contains("$") { return "@\(value)" }
            }
            return ""
        }
        if action.hasPrefix("actions/setup-node") {
            return VMEnvSpec.Step(name: "node", run: "mise use -g node\(version("node-version"))", timeoutMinutes: nil)
        }
        if action.hasPrefix("actions/setup-go") {
            return VMEnvSpec.Step(name: "go", run: "mise use -g go\(version("go-version"))", timeoutMinutes: nil)
        }
        if action.hasPrefix("actions/setup-python") {
            return VMEnvSpec.Step(name: "python", run: "mise use -g python\(version("python-version"))", timeoutMinutes: nil)
        }
        if action.hasPrefix("actions/setup-java") {
            return VMEnvSpec.Step(name: "java", run: "mise use -g java\(version("java-version"))", timeoutMinutes: nil)
        }
        if action.hasPrefix("oven-sh/setup-bun") {
            return VMEnvSpec.Step(name: "bun", run: "mise use -g bun\(version("bun-version"))", timeoutMinutes: nil)
        }
        if action.hasPrefix("dtolnay/rust-toolchain") || action.hasPrefix("actions-rust-lang/setup-rust-toolchain") {
            return VMEnvSpec.Step(name: "rust", run: "mise use -g rust\(version("toolchain"))", timeoutMinutes: nil)
        }
        if action.hasPrefix("mlugg/setup-zig") || action.hasPrefix("goto-bus-stop/setup-zig") {
            return VMEnvSpec.Step(name: "zig", run: "mise use -g zig\(version("version", "zig-version"))", timeoutMinutes: nil)
        }
        if action.hasPrefix("jdx/mise-action") {
            return VMEnvSpec.Step(name: "mise install", run: "mise install", timeoutMinutes: nil)
        }
        // checkout, caches, artifact upload/download, codecov etc.: CI plumbing.
        return nil
    }

    /// Runs that only make sense inside GitHub's runner.
    private static func isCIOnlyRun(_ run: String) -> Bool {
        let lower = run.lowercased()
        if lower.contains("github_output") || lower.contains("github_env") || lower.contains("github_step_summary") { return true }
        if lower.contains("actions/") { return true }
        return false
    }

    static func workflowScore(fileName: String, jobName: String, stepCount: Int) -> Int {
        var score = min(stepCount, 10)
        let haystack = (fileName + " " + jobName).lowercased()
        for (needle, bonus) in [("build", 20), ("test", 15), ("ci", 10), ("check", 5), ("lint", -5), ("release", -10), ("deploy", -15), ("docs", -10)] {
            if haystack.contains(needle) { score += bonus }
        }
        return score
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for char in line { if char == " " { count += 1 } else { break } }
        return count
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
            return ("bun.lock", "bun project", [
                VMEnvSpec.Step(name: "install dependencies", run: "cd \(repoName)\nbun install", timeoutMinutes: nil),
            ], ["cd \(repoName) && bun install --frozen-lockfile"])
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
