import CmuxFoundation
import Darwin
import Foundation

/// Runs one bounded git subprocess while containing its descendant process
/// group and sanitizing ambient repository-selection environment variables.
struct GitProcessRunner: Sendable {
    private static let nonLockingGitEnvironmentKey = "GIT_OPTIONAL_LOCKS"
    private static let nonLockingGitEnvironmentValue = "0"

    private let gitExecutableURL: URL
    private let environment: [String: String]
    private let processDeadlineSeconds: Double

    init(
        gitExecutableURL: URL,
        environment: [String: String],
        processDeadlineSeconds: Double
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.environment = environment
        self.processDeadlineSeconds = processDeadlineSeconds
    }

    func run(
        in directory: String,
        arguments: [String],
        acceptedTerminationStatuses: Set<Int32>,
        maxOutputBytes: Int?
    ) -> GitProcessResult {
        // A cancelled surrounding task (e.g. a timed-out mobile RPC whose
        // cancellation is forwarded into the detached git work) must not
        // spawn further subprocesses; outside any task this reads false.
        guard !Task.isCancelled else {
            return GitProcessResult(output: nil)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "set -m; /usr/bin/env -u SHELLOPTS -u BASHOPTS \"$@\" 2>/dev/null & child=$!; printf '%s\\n' \"$child\" >&2; exec 2>&-; wait \"$child\"; exit $?",
            "cmux-git",
            gitExecutableURL.path,
        ] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = nonLockingGitEnvironment()
        let pipe = Pipe()
        let processGroupPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = processGroupPipe
        do {
            try process.run()
            guard let processGroupIdentifier = Self.readProcessGroupIdentifier(
                processGroupPipe.fileHandleForReading
            ) else {
                process.terminate()
                process.waitUntilExit()
                return GitProcessResult(output: nil)
            }
            // Wall-clock watchdog: terminate git at the deadline so a stalled
            // subprocess never outlives the request that spawned it. The
            // cancellable timer source is the sanctioned bounded-delay shape
            // here (no async context exists for a Clock sleep, and the read
            // below blocks this thread).
            let watchdog = GitProcessWatchdog(
                process: process,
                processGroupIdentifier: processGroupIdentifier,
                outputHandle: pipe.fileHandleForReading
            )
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + processDeadlineSeconds)
            timer.setEventHandler { watchdog.fire() }
            timer.activate()
            defer { timer.cancel() }
            let read = Self.readOutput(
                pipe.fileHandleForReading,
                maxOutputBytes: maxOutputBytes,
                watchdog: watchdog
            )
            process.waitUntilExit()
            if read.capped {
                // We terminated git after reaching the output bound; its
                // exit status reflects our signal, not a git failure. Return
                // the bounded partial output and mark it cut off.
                return GitProcessResult(
                    output: Self.decodeUTF8DroppingPartialTail(read.data),
                    capped: true
                )
            }
            if watchdog.didFire {
                return GitProcessResult(output: nil, timedOut: true)
            }
            guard acceptedTerminationStatuses.contains(process.terminationStatus) else {
                return GitProcessResult(output: nil)
            }
            return GitProcessResult(output: String(data: read.data, encoding: .utf8))
        } catch {
            return GitProcessResult(output: nil)
        }
    }

    /// The wrapper shell starts git as a monitored background job, which gives
    /// git a dedicated process group, then reports that group leader here over
    /// its otherwise-discarded stderr. Keeping the wrapper outside the group
    /// lets it reap git after the watchdog signals the full descendant group.
    private static func readProcessGroupIdentifier(_ handle: FileHandle) -> pid_t? {
        guard let data = try? handle.read(upToCount: 64),
              let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1).first,
              let identifier = pid_t(firstLine),
              identifier > 0 else { return nil }
        return identifier
    }

    /// Drains process stdout, stopping (and terminating the process) once
    /// `maxOutputBytes` is reached so a huge diff never accumulates unbounded
    /// memory before response-level capping.
    private static func readOutput(
        _ handle: FileHandle,
        maxOutputBytes: Int?,
        watchdog: GitProcessWatchdog
    ) -> (data: Data, capped: Bool) {
        guard let maxOutputBytes else {
            return (handle.readDataToEndOfFileOrEmpty(), false)
        }
        var data = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty else {
                return (data, false)
            }
            data.append(chunk)
            if data.count >= maxOutputBytes {
                watchdog.fire()
                return (Data(data.prefix(maxOutputBytes)), true)
            }
        }
    }

    /// Decodes capped output, dropping at most one trailing partial UTF-8
    /// scalar introduced by the byte-bounded cut.
    private static func decodeUTF8DroppingPartialTail(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        var trimmed = data
        for _ in 0..<3 {
            guard !trimmed.isEmpty else { break }
            trimmed.removeLast()
            if let text = String(data: trimmed, encoding: .utf8) { return text }
        }
        return nil
    }

    /// Ambient git repository-selection variables that would make a subprocess
    /// ignore its working directory and resolve or diff a different repository.
    private static let scrubbedGitEnvironmentKeys: Set<String> = [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_NAMESPACE",
        "GIT_PREFIX",
        "GIT_CEILING_DIRECTORIES",
        // Diff output feeds a machine parser; an ambient external diff
        // driver must not execute or replace the unified format.
        "GIT_EXTERNAL_DIFF",
    ]

    private func nonLockingGitEnvironment() -> [String: String] {
        var environment = environment
        for key in Self.scrubbedGitEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment[Self.nonLockingGitEnvironmentKey] = Self.nonLockingGitEnvironmentValue
        return environment
    }
}

struct GitProcessResult {
    let output: String?
    /// Whether the output was cut off at the caller's byte bound.
    let capped: Bool
    let timedOut: Bool

    init(output: String?, capped: Bool = false, timedOut: Bool = false) {
        self.output = output
        self.capped = capped
        self.timedOut = timedOut
    }

    var successOutput: String? {
        output
    }
}
