import CmuxNextWakeups
import Foundation

/// What one `git` run printed on its output and how it exited.
nonisolated struct MarkdownGitOutput: Equatable, Sendable {
    var status: Int32
    var data: Data

    var output: String { String(decoding: data, as: UTF8.self) }
}

/// Runs read-only `git` commands for the Markdown omnibar; tests may pass a fake.
nonisolated protocol MarkdownGitRunning: Sendable {
    /// A runner confined for the repository containing `folder`; nil when its executable Git
    /// configuration cannot be neutralized. Fakes use the default no-op preparation.
    func confined(to folder: String) async -> (any MarkdownGitRunning)?
    /// `git -C folder <arguments>`; nil when git did not run or ran past its deadline.
    func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput?
}

extension MarkdownGitRunning {
    func confined(to _: String) async -> (any MarkdownGitRunning)? { self }
}

/// `/usr/bin/git` with no prompts and no optional locks (a status never takes the index lock an
/// editor or agent may hold), stopped at a deadline so a hung filesystem never holds the bar.
nonisolated struct ProcessMarkdownGitRunner: MarkdownGitRunning {
    var timeout: Duration = .seconds(5)
    private var filterOverrides: [(key: String, value: String)]?

    /// Git still reads the repository's data configuration, but it cannot select programs to
    /// execute. The fixed environment also keeps launcher-supplied `GIT_*` overrides out.
    private static let safeConfiguration = [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "log.showSignature=false",
        "-c", "diff.submodule=short",
        "-c", "core.attributesFile=/dev/null",
        "-c", "diff.orderFile=/dev/null",
    ]
    private static let baseEnvironment = [
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_ALLOW_PROTOCOL": "",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "HOME": "/var/empty",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "XDG_CONFIG_HOME": "/var/empty",
    ]

    func confined(to folder: String) async -> (any MarkdownGitRunning)? {
        let pattern = #"^filter\..*\.(clean|smudge|process|required)$"#
        guard let configured = await rawRun(["config", "--null", "--name-only", "--get-regexp", pattern], in: folder) else {
            return nil
        }
        let overrides: [(key: String, value: String)]
        if configured.status == 1, configured.data.isEmpty {
            overrides = []
        } else {
            guard configured.status == 0, let parsed = Self.filterOverrides(from: configured.data) else { return nil }
            overrides = parsed
        }
        var confined = self
        confined.filterOverrides = overrides
        return confined
    }

    func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? {
        guard filterOverrides != nil else {
            guard let confined = await confined(to: folder) as? Self else { return nil }
            return await confined.run(arguments, in: folder)
        }
        return await rawRun(arguments, in: folder)
    }

    private func rawRun(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? {
        guard folder.hasPrefix("/"), !folder.contains("\0") else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = Self.safeConfiguration + ["-C", folder] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.environment = environment
        do { try process.run() } catch { return nil }
        let running = process
        // The raw descriptor crosses into the reading task (a FileHandle is not Sendable); the
        // pipe stays open while `running` holds it as its output.
        let descriptor = output.fileHandleForReading.fileDescriptor
        // A one-shot deadline for this git run, cancelled as soon as the run returns.
        let deadline = DemandTimer(owner: "markdown-omnibar.git")
        deadline.schedule(after: timeout) { if running.isRunning { running.terminate() } }
        defer { deadline.cancel() }
        return await Task.detached(priority: .utility) {
            // concurrency-allow: blocking read and wait inside this detached utility task; git's
            // output for one file is small, and the deadline above ends a hung run.
            let data = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
            // concurrency-allow: git closed its output (EOF above), so it has exited or is exiting.
            running.waitUntilExit()
            guard running.terminationReason == .exit else { return nil }
            return MarkdownGitOutput(status: running.terminationStatus, data: data)
        }.value
    }

    private var environment: [String: String] {
        var environment = Self.baseEnvironment
        let overrides = filterOverrides ?? []
        environment["GIT_CONFIG_COUNT"] = String(overrides.count)
        for (index, override) in overrides.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = override.key
            environment["GIT_CONFIG_VALUE_\(index)"] = override.value
        }
        return environment
    }

    private static func filterOverrides(from data: Data) -> [(key: String, value: String)]? {
        guard data.count <= 64 * 1024, let output = String(data: data, encoding: .utf8) else { return nil }
        let settings = Set(["clean", "smudge", "process", "required"])
        var drivers: Set<String> = []
        for field in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let key = String(field)
            guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), settings.contains(String(key[key.index(after: dot)...])) else {
                return nil
            }
            let driver = String(key[key.index(key.startIndex, offsetBy: "filter.".count)..<dot])
            guard !driver.isEmpty else { return nil }
            drivers.insert(driver)
        }
        guard drivers.count <= 256 else { return nil }
        return drivers.sorted().flatMap { driver in
            [("filter.\(driver).clean", ""), ("filter.\(driver).smudge", ""),
             ("filter.\(driver).process", ""), ("filter.\(driver).required", "false")]
        }
    }
}
