import Darwin
import Foundation

/// Runs one bounded Git or filesystem-helper subprocess while containing its
/// descendant process group and sanitizing ambient repository-selection state.
struct GitProcessRunner: Sendable {
    private static let nonLockingGitEnvironmentKey = "GIT_OPTIONAL_LOCKS"
    private static let nonLockingGitEnvironmentValue = "0"
    private static let fileSystemStatFormat = "%d|%i|%p|%z|%Fm|%Fc"
    /// Leaves ample headroom below macOS `ARG_MAX` for the environment and
    /// supervised process arguments.
    private static let fileSystemArgumentBytesPerBatch = 64 * 1024

    private let gitExecutableURL: URL
    private let fileSystemStatExecutableURL: URL
    private let environment: [String: String]
    private let processDeadlineSeconds: Double
    private let processLifecycle: GitProcessLifecycleService

    init(
        gitExecutableURL: URL,
        fileSystemStatExecutableURL: URL,
        environment: [String: String],
        processDeadlineSeconds: Double,
        processLifecycle: GitProcessLifecycleService
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.fileSystemStatExecutableURL = fileSystemStatExecutableURL
        self.environment = environment
        self.processDeadlineSeconds = processDeadlineSeconds
        self.processLifecycle = processLifecycle
    }

    func run(
        in directory: String,
        arguments: [String],
        acceptedTerminationStatuses: Set<Int32>,
        maxOutputBytes: Int?,
        deadlineSeconds: Double? = nil
    ) -> GitProcessResult {
        runExecutable(
            executableURL: gitExecutableURL,
            arguments: ["-C", directory] + arguments,
            acceptedTerminationStatuses: acceptedTerminationStatuses,
            maxOutputBytes: maxOutputBytes,
            deadlineSeconds: deadlineSeconds
        )
    }

    func runFileSystemStat(
        paths: [String],
        allowMissing: Bool,
        maxOutputBytes: Int,
        deadlineSeconds: Double? = nil
    ) -> GitProcessResult {
        guard !paths.isEmpty else {
            return GitProcessResult(rawOutput: Data(), output: "", terminationStatus: 0)
        }
        let deadline = ProcessInfo.processInfo.systemUptime
            + effectiveDeadlineSeconds(deadlineSeconds)
        var accumulatedOutput = Data()
        for batch in argumentBatches(paths) {
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
                    output: decodeUTF8Lossy(
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
            output: decodeUTF8Lossy(accumulatedOutput, maxOutputBytes: nil),
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

    func runGitlinkWorkingTreeStates(
        repoRoot: String,
        paths: [String],
        maxOutputBytes: Int,
        deadlineSeconds: Double? = nil
    ) -> GitProcessResult {
        guard !paths.isEmpty else {
            return GitProcessResult(rawOutput: Data(), output: "", terminationStatus: 0)
        }
        let deadline = ProcessInfo.processInfo.systemUptime
            + effectiveDeadlineSeconds(deadlineSeconds)
        var accumulatedOutput = Data()
        for batch in argumentBatches(paths) {
            guard !Task.isCancelled else {
                return GitProcessResult(output: nil, failure: .cancelled)
            }
            let remainingSeconds = deadline - ProcessInfo.processInfo.systemUptime
            guard remainingSeconds > 0 else {
                return GitProcessResult(output: nil, failure: .timedOut)
            }
            let result = runExecutable(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    """
                    git=$1
                    root=$2
                    shift 2
                    root_gitdir=$("$git" -C "$root" rev-parse --absolute-git-dir 2>/dev/null) || exit $?
                    for path do
                      location=$root/$path
                      gitdir=$("$git" -C "$location" rev-parse --absolute-git-dir 2>/dev/null) || gitdir=
                      if [ -n "$gitdir" ] && [ "$gitdir" != "$root_gitdir" ]; then
                        state=$("$git" -C "$location" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || state=
                        if [ -n "$state" ]; then
                          "$git" -C "$location" diff-index --quiet --ignore-submodules=none HEAD --
                          dirty_status=$?
                          if [ "$dirty_status" -gt 1 ]; then exit "$dirty_status"; fi
                          if [ "$dirty_status" -eq 1 ] || [ -n "$("$git" -C "$location" ls-files --others --exclude-standard --directory --no-empty-directory | /usr/bin/head -n 1)" ]; then
                            state=$state-dirty
                          fi
                        fi
                      else
                        state=
                      fi
                      printf '%s\\000%s\\000' "$path" "$state"
                    done
                    """,
                    "cmux-gitlink-state",
                    gitExecutableURL.path,
                    repoRoot,
                ] + batch,
                acceptedTerminationStatuses: [0],
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
                    output: decodeUTF8Lossy(
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
            output: decodeUTF8Lossy(accumulatedOutput, maxOutputBytes: nil),
            terminationStatus: 0
        )
    }

    private func argumentBatches(_ paths: [String]) -> [[String]] {
        var batches: [[String]] = []
        var batch: [String] = []
        var batchBytes = 0
        for path in paths {
            let pathBytes = path.utf8.count + 1
            if !batch.isEmpty, batchBytes + pathBytes > Self.fileSystemArgumentBytesPerBatch {
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
        guard let lifecyclePermit = processLifecycle.beginProcess() else {
            return GitProcessResult(output: nil, failure: .launchFailed)
        }
        let supervised = GitSubprocessSupervisor(
            executableURL: executableURL,
            arguments: arguments,
            environment: nonLockingGitEnvironment(),
            deadlineSeconds: effectiveDeadlineSeconds(deadlineSeconds),
            maxOutputBytes: maxOutputBytes,
            processLifecycle: processLifecycle,
            lifecyclePermit: lifecyclePermit
        ).run()
        return translateSupervisedResult(
            supervised,
            acceptedTerminationStatuses: acceptedTerminationStatuses,
            maxOutputBytes: maxOutputBytes
        )
    }

    func translateSupervisedResult(
        _ supervised: GitProcessResult,
        acceptedTerminationStatuses: Set<Int32>,
        maxOutputBytes: Int?
    ) -> GitProcessResult {
        if let failure = supervised.failure {
            return GitProcessResult(
                output: nil,
                failure: failure,
                terminationStatus: supervised.terminationStatus
            )
        }
        if supervised.capped, let output = supervised.rawOutput {
            if !supervised.terminatedForOutputCap {
                guard let terminationStatus = supervised.terminationStatus,
                      acceptedTerminationStatuses.contains(terminationStatus) else {
                    return GitProcessResult(
                        output: nil,
                        failure: .unsuccessfulExit,
                        terminationStatus: supervised.terminationStatus
                    )
                }
            }
            return GitProcessResult(
                rawOutput: output,
                output: decodeUTF8Lossy(output, maxOutputBytes: maxOutputBytes),
                capped: true,
                terminationStatus: supervised.terminationStatus
            )
        }
        guard let terminationStatus = supervised.terminationStatus,
              acceptedTerminationStatuses.contains(terminationStatus),
              let output = supervised.rawOutput else {
            return GitProcessResult(
                output: nil,
                failure: .unsuccessfulExit,
                terminationStatus: supervised.terminationStatus
            )
        }
        return GitProcessResult(
            rawOutput: output,
            output: decodeUTF8Lossy(output, maxOutputBytes: nil),
            terminationStatus: terminationStatus
        )
    }

    private func effectiveDeadlineSeconds(_ requested: Double?) -> Double {
        max(0, min(processDeadlineSeconds, requested ?? processDeadlineSeconds))
    }

    /// Git emits raw bytes. Replace invalid UTF-8 instead of turning a valid
    /// command into an apparent Git failure, then preserve the caller's byte
    /// bound after replacement scalars expand in UTF-8.
    private func decodeUTF8Lossy(_ data: Data, maxOutputBytes: Int?) -> String {
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
        // These variables can execute startup files or mutate the interpreter
        // behavior of a configured Git executable before it handles arguments.
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
