import CmuxFoundation
import Darwin
import Foundation

/// Runs one bounded Git or filesystem-helper subprocess while containing its
/// descendant process group and sanitizing ambient repository-selection state.
struct GitProcessRunner: Sendable {
    private static let nonLockingGitEnvironmentKey = "GIT_OPTIONAL_LOCKS"
    private static let nonLockingGitEnvironmentValue = "0"
    private static let fileSystemStatFormat = "%d|%i|%p|%z|%Fm|%Fc"
    /// Leaves ample headroom below macOS `ARG_MAX` for the environment and
    /// process-group wrapper arguments.
    private static let fileSystemArgumentBytesPerBatch = 64 * 1024

    private let gitExecutableURL: URL
    private let fileSystemStatExecutableURL: URL
    private let environment: [String: String]
    private let processDeadlineSeconds: Double

    init(
        gitExecutableURL: URL,
        fileSystemStatExecutableURL: URL,
        environment: [String: String],
        processDeadlineSeconds: Double
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.fileSystemStatExecutableURL = fileSystemStatExecutableURL
        self.environment = environment
        self.processDeadlineSeconds = processDeadlineSeconds
    }

    func run(
        in directory: String,
        arguments: [String],
        acceptedTerminationStatuses: Set<Int32>,
        maxOutputBytes: Int?
    ) -> GitProcessResult {
        runExecutable(
            executableURL: gitExecutableURL,
            arguments: ["-C", directory] + arguments,
            acceptedTerminationStatuses: acceptedTerminationStatuses,
            maxOutputBytes: maxOutputBytes
        )
    }

    func runFileSystemStat(
        paths: [String],
        allowMissing: Bool,
        maxOutputBytes: Int
    ) -> GitProcessResult {
        guard !paths.isEmpty else {
            return GitProcessResult(rawOutput: Data(), output: "", terminationStatus: 0)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + processDeadlineSeconds
        var accumulatedOutput = Data()
        for batch in Self.fileSystemPathBatches(paths) {
            guard !Task.isCancelled else {
                return GitProcessResult(output: nil, failure: .cancelled)
            }
            let remainingSeconds = deadline - ProcessInfo.processInfo.systemUptime
            guard remainingSeconds > 0 else {
                return GitProcessResult(output: nil, failure: .timedOut)
            }
            let result = runFileSystemStatBatch(
                paths: batch,
                allowMissing: allowMissing,
                maxOutputBytes: max(1, maxOutputBytes - accumulatedOutput.count),
                deadlineSeconds: remainingSeconds
            )
            if result.failure != nil { return result }
            guard let output = result.rawOutput else {
                return GitProcessResult(output: nil, failure: .launchFailed)
            }
            accumulatedOutput.append(output)
            if result.capped {
                return GitProcessResult(
                    rawOutput: accumulatedOutput,
                    output: Self.decodeUTF8Lossy(
                        accumulatedOutput,
                        maxOutputBytes: maxOutputBytes
                    ),
                    capped: true,
                    terminationStatus: result.terminationStatus
                )
            }
        }
        return GitProcessResult(
            rawOutput: accumulatedOutput,
            output: Self.decodeUTF8Lossy(accumulatedOutput, maxOutputBytes: nil),
            terminationStatus: 0
        )
    }

    private func runFileSystemStatBatch(
        paths: [String],
        allowMissing: Bool,
        maxOutputBytes: Int,
        deadlineSeconds: Double
    ) -> GitProcessResult {
        if allowMissing {
            return runExecutable(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "stat=$1; format=$2; shift 2; for path do if [ ! -e \"$path\" ] && [ ! -L \"$path\" ]; then printf 'missing\\n'; else \"$stat\" -f \"$format\" -- \"$path\" || exit $?; fi; done",
                    "cmux-stat",
                    fileSystemStatExecutableURL.path,
                    Self.fileSystemStatFormat,
                ] + paths,
                acceptedTerminationStatuses: [0],
                maxOutputBytes: maxOutputBytes,
                deadlineSeconds: deadlineSeconds
            )
        }
        return runExecutable(
            executableURL: fileSystemStatExecutableURL,
            arguments: ["-f", Self.fileSystemStatFormat, "--"] + paths,
            acceptedTerminationStatuses: [0],
            maxOutputBytes: maxOutputBytes,
            deadlineSeconds: deadlineSeconds
        )
    }

    private static func fileSystemPathBatches(_ paths: [String]) -> [[String]] {
        var batches: [[String]] = []
        var batch: [String] = []
        var batchBytes = 0
        for path in paths {
            let pathBytes = path.utf8.count + 1
            if !batch.isEmpty, batchBytes + pathBytes > fileSystemArgumentBytesPerBatch {
                batches.append(batch)
                batch = []
                batchBytes = 0
            }
            batch.append(path)
            batchBytes += pathBytes
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    private func runExecutable(
        executableURL: URL,
        arguments: [String],
        acceptedTerminationStatuses: Set<Int32>,
        maxOutputBytes: Int?,
        deadlineSeconds: Double? = nil
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
            executableURL.path,
        ] + arguments
        // Launch only from a local, stable directory. Git receives `-C` and
        // filesystem helpers receive absolute paths after entering the
        // supervised process group, so remote filesystem access is watched.
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
            // Wall-clock watchdog: terminate the helper at the deadline so a stalled
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
            timer.schedule(deadline: .now() + (deadlineSeconds ?? processDeadlineSeconds))
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
                // We terminated the helper after reaching the output bound;
                // its exit status reflects our signal. Return
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

    /// The wrapper shell starts the helper as a monitored background job, which
    /// gives it a dedicated process group, then reports that leader here over
    /// its otherwise-discarded stderr. Keeping the wrapper outside the group
    /// lets it reap the helper after the watchdog signals its descendant group.
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
        // Exact-file diffs use explicit pathspec magic. Ambient pathspec modes
        // can disable that magic or make literal matches case-insensitive.
        "GIT_LITERAL_PATHSPECS",
        "GIT_GLOB_PATHSPECS",
        "GIT_NOGLOB_PATHSPECS",
        "GIT_ICASE_PATHSPECS",
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

struct GitProcessResult: Sendable {
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
