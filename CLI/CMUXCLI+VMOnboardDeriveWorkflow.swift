import Foundation

/// GitHub-workflow branch of the `cmux vm onboard` derivation ladder: pick the
/// best Linux build/test job from `.github/workflows/*` and translate its steps
/// into env-spec layers. Split from `CMUXCLI+VMOnboardDerive.swift` to keep
/// both files within the repo's Swift file length budget.
extension VMOnboardDeriver {
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
                // Only Linux jobs translate to a Linux VM. Expression-valued
                // runs-on (e.g. `${{ matrix.os }}`) cannot be resolved
                // statically; keep the job and let scoring pick the best one.
                let runsOn = job.runsOn?.lowercased() ?? ""
                if runsOn.isEmpty || runsOn.contains("ubuntu") || runsOn.contains("linux") || runsOn.contains("${{") {
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

    /// Runs that only make sense inside GitHub's runner: writes to the runner's
    /// step-communication files. Kept narrow on purpose — a command merely
    /// mentioning a path like `actions/` is still a real project command.
    private static func isCIOnlyRun(_ run: String) -> Bool {
        let lower = run.lowercased()
        return lower.contains("github_output") || lower.contains("github_env") || lower.contains("github_step_summary")
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
}
