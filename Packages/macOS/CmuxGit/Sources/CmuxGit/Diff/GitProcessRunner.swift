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
            return GitProcessResult(output: nil, failure: .cancelled)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "set -m; /usr/bin/env -u SHELLOPTS -u BASHOPTS \"$@\" 2>/dev/null & child=$!; printf '%s\\n' \"$child\" >&2; exec 2>&-; wait \"$child\"; exit $?",
            "cmux-git",
            gitExecutableURL.path,
        ] + ["-C", directory] + arguments
        // Launch only from a local, stable directory. Git performs the
        // repository chdir after entering the supervised process group, so a
        // stalled network filesystem is covered by the subprocess deadline.
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
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
                return GitProcessResult(output: nil, failure: .launchFailed)
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
            watchdog.cancelEscalation()
            if read.capped {
                // We terminated git after reaching the output bound; its
                // exit status reflects our signal, not a git failure. Return
                // the bounded partial output and mark it cut off.
                return GitProcessResult(
                    rawOutput: read.data,
                    output: Self.decodeUTF8Lossy(read.data, maxOutputBytes: maxOutputBytes),
                    capped: true,
                    terminationStatus: process.terminationStatus
                )
            }
            if watchdog.didFire {
                return GitProcessResult(
                    output: nil,
                    failure: .timedOut,
                    terminationStatus: process.terminationStatus
                )
            }
            guard acceptedTerminationStatuses.contains(process.terminationStatus) else {
                return GitProcessResult(
                    output: nil,
                    failure: .unsuccessfulExit,
                    terminationStatus: process.terminationStatus
                )
            }
            return GitProcessResult(
                rawOutput: read.data,
                output: Self.decodeUTF8Lossy(read.data, maxOutputBytes: nil),
                terminationStatus: process.terminationStatus
            )
        } catch {
            return GitProcessResult(output: nil, failure: .launchFailed)
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

    /// Git emits raw bytes. Replace invalid UTF-8 instead of turning a valid
    /// command into an apparent Git failure, then preserve the caller's byte
    /// bound after replacement scalars expand in UTF-8.
    private static func decodeUTF8Lossy(_ data: Data, maxOutputBytes: Int?) -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard let maxOutputBytes, text.utf8.count > maxOutputBytes else { return text }
        let utf8 = text.utf8
        var boundary = utf8.index(utf8.startIndex, offsetBy: maxOutputBytes)
        while String.Index(boundary, within: text) == nil {
            boundary = utf8.index(before: boundary)
        }
        let stringBoundary = String.Index(boundary, within: text) ?? text.startIndex
        return String(text[..<stringBoundary])
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
        // These variables can execute startup files or mutate shell behavior
        // before the wrapper reaches its child-level `env -u` boundary.
        "SHELLOPTS",
        "BASHOPTS",
        "BASH_ENV",
        "ENV",
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
    /// Exact stdout bytes for protocols where byte identity matters, such as
    /// NUL-delimited Git paths. Human-readable diff content uses `output`.
    let rawOutput: Data?
    let output: String?
    /// Whether the output was cut off at the caller's byte bound.
    let capped: Bool
    let failure: GitProcessFailure?
    /// Exit status when a Git subprocess launched and terminated.
    let terminationStatus: Int32?

    init(
        rawOutput: Data? = nil,
        output: String?,
        capped: Bool = false,
        failure: GitProcessFailure? = nil,
        terminationStatus: Int32? = nil
    ) {
        self.rawOutput = rawOutput
        self.output = output
        self.capped = capped
        self.failure = failure
        self.terminationStatus = terminationStatus
    }

    var timedOut: Bool { failure == .timedOut }

    var successOutput: String? {
        output
    }
}

enum GitProcessFailure: Sendable {
    case cancelled
    case timedOut
    case launchFailed
    case unsuccessfulExit
}
