import Foundation

enum PromptLauncherCommandEvent: Sendable, Equatable {
    case output(String)
    case finished(exitStatus: Int32)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .output:
            false
        case .finished, .failed:
            true
        }
    }
}

protocol PromptLauncherCommandRunning: Sendable {
    func events(
        shellCommand: String,
        environment: [String: String],
        forwardedSocketPath: String?
    ) async -> AsyncStream<PromptLauncherCommandEvent>
}

struct PromptLauncherProcessRunner: PromptLauncherCommandRunning {
    func events(
        shellCommand: String,
        environment: [String: String],
        forwardedSocketPath: String?
    ) async -> AsyncStream<PromptLauncherCommandEvent> {
        AsyncStream { continuation in
            let state = ProcessState(continuation: continuation)
            state.start(
                shellCommand: shellCommand,
                environment: environment,
                forwardedSocketPath: forwardedSocketPath
            )
        }
    }

    /// `Process` invokes its handlers on arbitrary threads. Every mutable field in
    /// this holder is protected by `lock`; the unchecked conformance is limited to
    /// bridging Foundation's non-Sendable process APIs into an `AsyncStream`.
    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncStream<PromptLauncherCommandEvent>.Continuation
        private var process: Process?
        private var pipe: Pipe?
        private var bufferedText = ""
        private var finished = false

        init(continuation: AsyncStream<PromptLauncherCommandEvent>.Continuation) {
            self.continuation = continuation
        }

        func start(
            shellCommand: String,
            environment: [String: String],
            forwardedSocketPath: String?
        ) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", shellCommand]

            var processEnvironment = ProcessInfo.processInfo.environment
            processEnvironment.merge(environment) { _, configuredValue in configuredValue }
            if let forwardedSocketPath {
                processEnvironment["CMUX_SOCKET_PATH"] = forwardedSocketPath
            }
            process.environment = processEnvironment
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            self.process = process
            self.pipe = pipe

            // The handlers retain this state until termination so the process and
            // stream stay alive after `events` returns.
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                consume(handle.availableData, flushRemainder: false)
            }
            process.terminationHandler = { [self] process in
                pipe.fileHandleForReading.readabilityHandler = nil
                consume(pipe.fileHandleForReading.readDataToEndOfFile(), flushRemainder: true)
                finish(with: .finished(exitStatus: process.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                finish(with: .failed(error.localizedDescription))
            }
        }

        private func consume(_ data: Data, flushRemainder: Bool) {
            guard !data.isEmpty || flushRemainder else { return }
            let decoded = String(decoding: data, as: UTF8.self)
            let lines: [String]
            lock.lock()
            bufferedText += decoded
            var components = bufferedText.components(separatedBy: .newlines)
            if flushRemainder {
                bufferedText = ""
            } else {
                bufferedText = components.popLast() ?? ""
            }
            lines = components
            lock.unlock()

            for line in lines {
                let cleaned = SidebarPromptLauncherTemplateRenderer.stripAnsi(line)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    continuation.yield(.output(cleaned))
                }
            }
        }

        private func finish(with event: PromptLauncherCommandEvent) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            process = nil
            pipe = nil
            lock.unlock()

            continuation.yield(event)
            continuation.finish()
        }
    }
}
