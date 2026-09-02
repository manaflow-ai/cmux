import Darwin
public import Foundation

/// Implements the headless `cmux sudo` and compatibility-wrapper workflow.
public struct SudoCLICommand {
    private let store: SudoSpoolStore
    private let appBundleURL: URL
    private let currentDirectoryURL: URL
    private let requesterIdentity: SudoProcessIdentity
    private let requesterCommand: String
    private let launcher: any SudoAppLaunching
    private let setupLauncher: any SudoTouchIDSetupLaunching
    private let setupHelperURL: URL
    private let io: SudoCLIIO
    private let messages: SudoCLIMessages
    private let failureMessages: SudoFailureMessages
    private let inputReader: SudoBoundedInputReader
    private let now: () -> Date

    /// Creates the production sudo command for one enclosing cmux app bundle.
    ///
    /// - Parameters:
    ///   - paths: The enclosing app bundle's private sudo spool.
    ///   - appBundleURL: The exact enclosing `.app` URL opened for approval.
    ///   - currentDirectoryURL: The script working directory.
    ///   - requesterIdentity: The generation-qualified process requesting execution.
    ///   - requesterCommand: The requester name shown during approval.
    public init(
        paths: SudoBrokerPaths,
        appBundleURL: URL,
        currentDirectoryURL: URL,
        requesterIdentity: SudoProcessIdentity,
        requesterCommand: String
    ) {
        let inspector = SystemSudoProcessInspector()
        store = SudoSpoolStore(paths: paths)
        self.appBundleURL = appBundleURL
        self.currentDirectoryURL = currentDirectoryURL.standardizedFileURL
        self.requesterIdentity = requesterIdentity
        self.requesterCommand = requesterCommand
        launcher = SystemSudoAppLauncher(
            inspector: inspector,
            signaler: SystemSudoProcessSignaler()
        )
        setupLauncher = SystemSudoTouchIDSetupLauncher()
        setupHelperURL = appBundleURL.appendingPathComponent(
            "Contents/Resources/bin/setup-pam-tid.sh",
            isDirectory: false
        )
        io = .live
        messages = SudoCLIMessages()
        failureMessages = .localized
        inputReader = SudoBoundedInputReader()
        now = { .now }
    }

    init(
        store: SudoSpoolStore,
        appBundleURL: URL,
        currentDirectoryURL: URL,
        requesterIdentity: SudoProcessIdentity,
        requesterCommand: String,
        launcher: any SudoAppLaunching,
        setupLauncher: any SudoTouchIDSetupLaunching = SystemSudoTouchIDSetupLauncher(),
        setupHelperURL: URL? = nil,
        io: SudoCLIIO,
        messages: SudoCLIMessages = SudoCLIMessages(),
        failureMessages: SudoFailureMessages,
        inputReader: SudoBoundedInputReader = SudoBoundedInputReader(),
        now: @escaping () -> Date
    ) {
        self.store = store
        self.appBundleURL = appBundleURL
        self.currentDirectoryURL = currentDirectoryURL
        self.requesterIdentity = requesterIdentity
        self.requesterCommand = requesterCommand
        self.launcher = launcher
        self.setupLauncher = setupLauncher
        self.setupHelperURL = setupHelperURL ?? appBundleURL.appendingPathComponent(
            "Contents/Resources/bin/setup-pam-tid.sh",
            isDirectory: false
        )
        self.io = io
        self.messages = messages
        self.failureMessages = failureMessages
        self.inputReader = inputReader
        self.now = now
    }

    /// Runs a sudo CLI subcommand.
    ///
    /// - Parameter arguments: Arguments after `cmux sudo`.
    /// - Returns: The approved script's exit code, or a broker-specific code.
    /// - Throws: ``SudoCLICommandError`` for usage or setup failures.
    public func run(arguments: [String]) throws -> Int32 {
        guard let subcommand = arguments.first else {
            throw SudoCLICommandError(message: messages.usage, exitCode: 2)
        }
        let remaining = Array(arguments.dropFirst())
        switch subcommand {
        case "-h", "--help", "help":
            try io.writeStandardOutput(Data((messages.usage + "\n").utf8))
            return 0
        case "pending":
            guard remaining.isEmpty else {
                throw SudoCLICommandError(
                    message: messages.unexpectedArgument(remaining[0]),
                    exitCode: 2
                )
            }
            return try listPending()
        case "setup-touch-id":
            guard remaining.isEmpty else {
                throw SudoCLICommandError(
                    message: messages.unexpectedArgument(remaining[0]),
                    exitCode: 2
                )
            }
            do {
                return try setupLauncher.run(helperURL: setupHelperURL)
            } catch {
                throw SudoCLICommandError(message: messages.touchIDSetupFailed)
            }
        case "run":
            if remaining == ["-h"] || remaining == ["--help"] {
                try io.writeStandardOutput(Data((messages.usage + "\n").utf8))
                return 0
            }
            return try runRequest(arguments: remaining)
        default:
            throw SudoCLICommandError(message: messages.usage, exitCode: 2)
        }
    }

    private func listPending() throws -> Int32 {
        try store.ensureDirectories()
        let identifiers = store.pendingRequests().map(\.request.id)
        let output = identifiers.isEmpty
            ? messages.noPendingRequests
            : identifiers.joined(separator: "\n")
        try io.writeStandardOutput(Data((output + "\n").utf8))
        return 0
    }

    private func runRequest(arguments: [String]) throws -> Int32 {
        let invocation = try parse(arguments)
        let script = try loadScript(invocation.source)
        let createdAt = now()
        let request = SudoRequest(
            id: requestIdentifier(createdAt: createdAt),
            reason: invocation.reason,
            requesterIdentity: requesterIdentity,
            requesterCommand: requesterCommand,
            currentDirectory: currentDirectoryURL.path,
            createdAt: createdAt,
            timeoutSeconds: invocation.timeoutSeconds
        )

        do {
            try store.enqueue(SudoPendingRequest(request: request, script: script))
        } catch SudoSpoolError.requestCapacityExceeded {
            throw SudoCLICommandError(message: messages.requestCapacityExceeded)
        } catch SudoSpoolError.scriptTooLarge {
            throw SudoCLICommandError(message: messages.scriptTooLarge, exitCode: 2)
        } catch {
            throw SudoCLICommandError(message: messages.requestWriteFailed)
        }

        do {
            try launcher.launch(appBundleURL: appBundleURL)
        } catch {
            _ = try? store.settle(
                SudoResult(
                    id: request.id,
                    status: .failed,
                    errorCode: .appLaunchFailed,
                    note: messages.appLaunchFailed
                )
            )
            throw SudoCLICommandError(message: messages.appLaunchFailed)
        }

        io.writeStandardError(
            messages.queued(id: request.id, timeoutSeconds: request.timeoutSeconds)
        )
        let waiter = SudoResultWaiter(store: store, io: io)
        let outcome: SudoResultWaitOutcome
        do {
            outcome = try waiter.wait(
                requestID: request.id,
                deadline: request.approvalDeadline,
                approvalTimeoutNote: failureMessages.approvalTimedOut
            )
        } catch {
            if let result = store.authoritativeResult(id: request.id) {
                return resultCode(.result(result), requestID: request.id)
            }
            let disposition = try? store.settlePendingTimeout(
                SudoResult(
                    id: request.id,
                    status: .failed,
                    errorCode: .resultWaitFailed,
                    note: messages.resultWaitFailed
                )
            )
            if disposition == .approvedExecution {
                return resultCode(.timedOut(.approvedExecution), requestID: request.id)
            }
            throw SudoCLICommandError(message: messages.resultWaitFailed)
        }
        return resultCode(outcome, requestID: request.id)
    }

    private func resultCode(
        _ outcome: SudoResultWaitOutcome,
        requestID: String
    ) -> Int32 {
        switch outcome {
        case .timedOut(.pendingApproval):
            io.writeStandardError(messages.pendingTimeout(id: requestID))
            return 124
        case .timedOut(.approvedExecution):
            io.writeStandardError(messages.approvedTimeout(id: requestID))
            return 124
        case .result(let result):
            if let note = result.note, !note.isEmpty {
                io.writeStandardError(note)
            }
            switch result.status {
            case .completed:
                return result.exitCode ?? 1
            case .denied:
                io.writeStandardError(messages.denied)
                return 77
            case .failed:
                io.writeStandardError(messages.failed)
                return result.exitCode.flatMap(Self.validExitCode) ?? 1
            }
        }
    }

    private func parse(_ arguments: [String]) throws -> Invocation {
        var reason = messages.defaultReason
        var timeoutSeconds = SudoRequest.defaultTimeoutSeconds
        var source: ScriptSource?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-r", "--reason":
                guard index + 1 < arguments.count else {
                    throw SudoCLICommandError(message: messages.usage, exitCode: 2)
                }
                reason = arguments[index + 1]
                index += 2
            case "-t", "--timeout":
                guard index + 1 < arguments.count else {
                    throw SudoCLICommandError(message: messages.usage, exitCode: 2)
                }
                let rawTimeout = arguments[index + 1]
                guard let parsed = Int(rawTimeout), parsed > 0 else {
                    throw SudoCLICommandError(
                        message: messages.timeoutPositiveInteger,
                        exitCode: 2
                    )
                }
                guard parsed <= SudoRequest.maximumTimeoutSeconds else {
                    throw SudoCLICommandError(
                        message: messages.timeoutTooLarge,
                        exitCode: 2
                    )
                }
                timeoutSeconds = parsed
                index += 2
            case "-c":
                guard index + 1 < arguments.count, source == nil else {
                    throw SudoCLICommandError(message: messages.usage, exitCode: 2)
                }
                source = .command(arguments[index + 1])
                index += 2
            case "-":
                guard source == nil else {
                    throw SudoCLICommandError(message: messages.usage, exitCode: 2)
                }
                source = .standardInput
                index += 1
            default:
                if argument.hasPrefix("-") {
                    throw SudoCLICommandError(
                        message: messages.unknownFlag(argument),
                        exitCode: 2
                    )
                }
                guard source == nil else {
                    throw SudoCLICommandError(
                        message: messages.unexpectedArgument(argument),
                        exitCode: 2
                    )
                }
                source = .file(URL(fileURLWithPath: (argument as NSString).expandingTildeInPath))
                index += 1
            }
        }
        guard let source else {
            throw SudoCLICommandError(message: messages.missingInput, exitCode: 2)
        }
        return Invocation(reason: reason, timeoutSeconds: timeoutSeconds, source: source)
    }

    private func loadScript(_ source: ScriptSource) throws -> String {
        let maximumBytes = store.resourcePolicy.maximumScriptBytes
        let overflowSentinelLimit = maximumBytes + 1
        let data: Data
        switch source {
        case .command(let command):
            data = Data((command + "\n").utf8)
        case .standardInput:
            do {
                data = try io.readStandardInput(overflowSentinelLimit)
            } catch SudoBoundedInputReader.Failure.tooLarge {
                throw SudoCLICommandError(message: messages.scriptTooLarge, exitCode: 2)
            } catch {
                throw SudoCLICommandError(message: messages.inputReadFailed, exitCode: 2)
            }
        case .file(let url):
            do {
                data = try inputReader.readRegularFile(
                    at: url,
                    maximumBytes: overflowSentinelLimit
                )
            } catch SudoBoundedInputReader.Failure.open(let code) where code == ENOENT {
                throw SudoCLICommandError(
                    message: messages.scriptNotFound(url.path),
                    exitCode: 2
                )
            } catch SudoBoundedInputReader.Failure.tooLarge {
                throw SudoCLICommandError(message: messages.scriptTooLarge, exitCode: 2)
            } catch {
                throw SudoCLICommandError(
                    message: messages.scriptUnreadable(url.path),
                    exitCode: 2
                )
            }
        }
        guard data.count <= maximumBytes else {
            throw SudoCLICommandError(message: messages.scriptTooLarge, exitCode: 2)
        }
        guard let script = String(data: data, encoding: .utf8) else {
            throw SudoCLICommandError(message: messages.invalidUTF8, exitCode: 2)
        }
        return script
    }

    private func requestIdentifier(createdAt: Date) -> String {
        let milliseconds = Int64(createdAt.timeIntervalSince1970 * 1_000)
        return "\(milliseconds)-\(getpid())-\(UUID().uuidString.lowercased())"
    }

    private static func validExitCode(_ value: Int32) -> Int32? {
        (1...255).contains(value) ? value : nil
    }

    private struct Invocation {
        let reason: String
        let timeoutSeconds: Int
        let source: ScriptSource
    }

    private enum ScriptSource: Equatable {
        case command(String)
        case standardInput
        case file(URL)
    }
}
