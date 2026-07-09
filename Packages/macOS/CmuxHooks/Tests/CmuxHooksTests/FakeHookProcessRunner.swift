import CmuxHooks
import Foundation

actor FakeHookProcessRunner: HookProcessRunning {
    struct Invocation: Sendable, Equatable {
        let command: String
        let arguments: [String]
        let stdin: Data
        let timeout: Duration
    }

    enum Script: Sendable, Equatable {
        case immediate(HookProcessResult)
        case suspended(label: String, result: HookProcessResult)
        case delayed(label: String, result: HookProcessResult)
    }

    private var scripts: [Script]
    private var invocations: [Invocation] = []
    private var events: [String] = []
    private var suspended: [String: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    func run(command: String, arguments: [String], stdin: Data, timeout: Duration) async -> HookProcessResult {
        invocations.append(Invocation(command: command, arguments: arguments, stdin: stdin, timeout: timeout))
        let script = scripts.isEmpty
            ? .immediate(.successJSON(#"{"decision":"allow"}"#))
            : scripts.removeFirst()
        switch script {
        case .immediate(let result):
            events.append("start:\(command)")
            events.append("finish:\(command)")
            resumeWaiters()
            return result
        case .suspended(let label, let result):
            events.append("start:\(label)")
            resumeWaiters()
            await withCheckedContinuation { continuation in
                suspended[label] = continuation
            }
            events.append("finish:\(label)")
            resumeWaiters()
            return result
        case .delayed(let label, let result):
            events.append("start:\(label)")
            resumeWaiters()
            try? await Task.sleep(for: .milliseconds(100))
            events.append("finish:\(label)")
            resumeWaiters()
            return result
        }
    }

    func finish(_ label: String) {
        suspended.removeValue(forKey: label)?.resume()
    }

    func waitForEventCount(_ count: Int) async {
        if events.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }

    func recordedEvents() -> [String] {
        events
    }

    private func resumeWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if events.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

extension HookProcessResult {
    static func successJSON(_ json: String) -> HookProcessResult {
        HookProcessResult(
            exitStatus: 0,
            stdout: Data(json.utf8),
            stderr: Data(),
            timedOut: false,
            launchFailure: nil
        )
    }

    static func failure(exitStatus: Int32? = 1, stdout: Data = Data(), timedOut: Bool = false) -> HookProcessResult {
        HookProcessResult(
            exitStatus: exitStatus,
            stdout: stdout,
            stderr: Data(),
            timedOut: timedOut,
            launchFailure: nil
        )
    }

    static func launchFailure(_ message: String) -> HookProcessResult {
        HookProcessResult(
            exitStatus: nil,
            stdout: Data(),
            stderr: Data(),
            timedOut: false,
            launchFailure: message
        )
    }
}
