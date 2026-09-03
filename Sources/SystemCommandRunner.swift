import Darwin
import CoreGraphics
import Foundation
import Security

/// Real command runner. Blocking work happens on background queues and is
/// surfaced through async APIs, so awaiting callers (including MainActor UI)
/// suspend rather than block. Privileged work is serialized on a private queue
/// that also owns the `AuthorizationRef`, so there is no shared mutable global
/// and the admin prompt is not guarded by a lock held elsewhere.
/// `AuthorizationExecuteWithPrivileges` is Swift-unavailable, so it's loaded via
/// `dlsym` (deprecated but present); macOS caches the admin credential (~5 min)
/// so back-to-back toggles don't re-prompt.
final class SystemCommandRunner: SleepyCommandRunning, @unchecked Sendable {
    private typealias AuthExecFn = @convention(c) (
        AuthorizationRef?,
        UnsafePointer<CChar>?,
        UInt32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private static let authExec: AuthExecFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(symbol, to: AuthExecFn.self)
    }()

    private typealias LockScreenFn = @convention(c) () -> Void

    /// `SACLockScreenImmediate` from `login.framework` — the call behind the
    /// Apple menu's "Lock Screen" (⌃⌘Q), predating the macOS 14 deployment
    /// floor. It replaces shelling out to the `CGSession` binary, which macOS
    /// 26 removed together with `User.menu`
    /// (https://github.com/manaflow-ai/cmux/issues/9730). Resolved via `dlsym`
    /// like `authExec` above, so no private symbol is linked and a macOS that
    /// drops it degrades to a reported failure, not a crash. The private API has
    /// no documented return contract; established clients declare it `void`, so
    /// cmux verifies the resulting public lock signal instead of interpreting
    /// an undocumented return register as status.
    private static let lockScreenImmediate: LockScreenFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockScreenFn.self)
    }()

    private let lockScreenInvoker: (@Sendable () -> Void)?
    private let lockStateReader: @Sendable () -> Bool?
    /// The bounded grace period is only a recovery path when loginwindow never
    /// publishes a usable confirmation. Ten seconds covers delayed IPC on busy
    /// hosts while keeping a rejected request from disabling the UI forever.
    private let lockConfirmationClock: any Clock<Duration>
    private let lockConfirmationTimeout: Duration
    private let privilegedQueue = DispatchQueue(label: "com.cmux.sleepyMode.privileged")
    private var authorization: AuthorizationRef?  // accessed only on privilegedQueue

    convenience init(
        lockConfirmationClock: any Clock<Duration> = ContinuousClock(),
        lockConfirmationTimeout: Duration = .seconds(10)
    ) {
        self.init(
            lockConfirmationClock: lockConfirmationClock,
            lockConfirmationTimeout: lockConfirmationTimeout,
            lockScreenInvoker: Self.defaultLockScreenInvoker(),
            lockStateReader: { Self.screenLockState() }
        )
    }

    init(
        lockConfirmationClock: any Clock<Duration> = ContinuousClock(),
        lockConfirmationTimeout: Duration = .seconds(10),
        lockScreenInvoker: (@Sendable () -> Void)?,
        lockStateReader: @escaping @Sendable () -> Bool?
    ) {
        self.lockConfirmationClock = lockConfirmationClock
        self.lockConfirmationTimeout = lockConfirmationTimeout
        self.lockScreenInvoker = lockScreenInvoker
        self.lockStateReader = lockStateReader
    }

    func run(_ tool: String, _ args: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                continuation.resume()
            }
        }
    }

    func capture(_ tool: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    /// Asks loginwindow to lock without blocking the caller's actor. Returns
    /// only after the public session state confirms the transition. A request
    /// that never produces that state fails closed at the bounded confirmation
    /// deadline, or sooner when Sleepy Mode cancels its owning task.
    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func lockScreen() async -> Bool {
        await lockScreen(using: SleepyLockInvocationGate())
    }

    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func lockScreen(using gate: SleepyLockInvocationGate) async -> Bool {
        guard let lockScreenInvoker else { return false }

        let clock = lockConfirmationClock
        let timeout = lockConfirmationTimeout
        let stateReader = lockStateReader
        let invoked = gate.invoke {
            lockScreenInvoker()
        }
        guard invoked else { return false }
        if stateReader() == true {
            return true
        }
        return await Self.waitForLockConfirmation(
            clock: clock,
            timeout: timeout,
            stateReader: stateReader
        )
    }

    private static func waitForLockConfirmation(
        clock: any Clock<Duration>,
        timeout: Duration,
        stateReader: @escaping @Sendable () -> Bool?
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // Poll only the authoritative state. The distributed lock event
                // has no trusted sender or request identity, so it cannot safely
                // confirm this security-sensitive operation.
                return await Self.waitForCurrentLockState(
                    clock: clock,
                    stateReader: stateReader
                )
            }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            guard result else { return false }
            switch stateReader() {
            case .some(true):
                return true
            case .none:
                // Never claim a security lock without authoritative state.
                return false
            case .some(false):
                return false
            }
        }
    }

    private static func waitForCurrentLockState(
        clock: any Clock<Duration>,
        stateReader: @escaping @Sendable () -> Bool?
    ) async -> Bool {
        while !Task.isCancelled {
            switch stateReader() {
            case .some(true):
                return true
            case .none:
                do {
                    try await clock.sleep(for: .milliseconds(50))
                } catch {
                    return false
                }
            case .some(false):
                do {
                    try await clock.sleep(for: .milliseconds(50))
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private static func screenLockState() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return nil
        }
        return session["CGSSessionScreenIsLocked"] as? Bool
    }

    private static func defaultLockScreenInvoker() -> (@Sendable () -> Void)? {
        guard Self.lockScreenImmediate != nil else { return nil }
        return { Self.lockScreenImmediate?() }
    }

    @discardableResult
    func runPrivileged(_ tool: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            privilegedQueue.async {
                continuation.resume(returning: self.runPrivilegedOnQueue(tool, args))
            }
        }
    }

    // Runs only on privilegedQueue, which serializes access to `authorization`.
    private func runPrivilegedOnQueue(_ tool: String, _ args: [String]) -> Bool {
        guard let authExec = Self.authExec, let authorization = authorizationRefOnQueue() else { return false }
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { for pointer in cArgs where pointer != nil { free(pointer) } }
        var pipe: UnsafeMutablePointer<FILE>?
        let status = tool.withCString { toolPtr -> OSStatus in
            cArgs.withUnsafeMutableBufferPointer { buffer in
                authExec(authorization, toolPtr, 0, buffer.baseAddress, &pipe)
            }
        }
        // Drain to EOF so we block (on this background queue) until the tool
        // exits and callers can re-read accurate state.
        if let pipe {
            var line = [CChar](repeating: 0, count: 256)
            while fgets(&line, 256, pipe) != nil {}
            fclose(pipe)
        }
        return status == errAuthorizationSuccess
    }

    private func authorizationRefOnQueue() -> AuthorizationRef? {
        if let authorization { return authorization }
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }
        authorization = ref
        return ref
    }
}
