import Darwin
import Foundation
import OSLog
import Security

/// Logs system-command failures for Sleepy Mode's power actions, so a tool that
/// is missing or exits non-zero leaves a trace instead of vanishing.
nonisolated private let sleepyCommandLogger = Logger(subsystem: "com.cmuxterm.app", category: "SleepyMode.command")

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

    /// `SACLockScreenImmediate` from the private `login.framework`. Resolved
    /// lazily and cached; `nil` on a system that does not export it, which the
    /// caller reports rather than pretending the lock happened.
    private static let lockScreenImmediate: LockScreenFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockScreenFn.self)
    }()

    private let privilegedQueue = DispatchQueue(label: "com.cmux.sleepyMode.privileged")
    private var authorization: AuthorizationRef?  // accessed only on privilegedQueue

    /// Builds a process with both output streams discarded.
    ///
    /// - Parameters:
    ///   - tool: Absolute path of the executable.
    ///   - args: Arguments passed to the executable.
    /// - Returns: A configured, unstarted process.
    nonisolated private func makeProcess(_ tool: String, _ args: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Launches `tool` without waiting for it to exit, reporting whether the
    /// launch itself succeeded.
    ///
    /// The previous `try?` discarded that error, which turned a removed system
    /// tool into a button that silently did nothing; a launch failure is now
    /// both logged and returned.
    ///
    /// - Parameters:
    ///   - tool: Absolute path of the executable.
    ///   - args: Arguments passed to the executable.
    /// - Returns: `true` when the process started.
    @discardableResult
    nonisolated func run(_ tool: String, _ args: [String]) async -> Bool {
        do {
            try makeProcess(tool, args).run()
            return true
        } catch {
            sleepyCommandLogger.error("Failed to launch \(tool, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whether `tool` exists and is executable.
    ///
    /// - Parameter tool: Absolute path to probe.
    /// - Returns: `true` when the file can be executed.
    nonisolated func canRun(_ tool: String) async -> Bool {
        FileManager.default.isExecutableFile(atPath: tool)
    }

    /// Runs `tool` and resumes once it exits, reporting whether it exited zero.
    ///
    /// Termination is observed through `Process.terminationHandler` rather than
    /// `waitUntilExit()`, so no thread is parked waiting for the child.
    ///
    /// - Parameters:
    ///   - tool: Absolute path of the executable.
    ///   - args: Arguments passed to the executable.
    /// - Returns: `true` only on a zero exit status.
    @discardableResult
    nonisolated func runAwaitingExit(_ tool: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = makeProcess(tool, args)
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                if status != 0 {
                    sleepyCommandLogger.error("\(tool, privacy: .public) exited with status \(status, privacy: .public)")
                }
                continuation.resume(returning: status == 0)
            }
            do {
                try process.run()
            } catch {
                // The handler never fires for a process that never started, so
                // clear it and resume exactly once here.
                process.terminationHandler = nil
                sleepyCommandLogger.error("Failed to launch \(tool, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: false)
            }
        }
    }

    /// Locks the screen through `login.framework`'s `SACLockScreenImmediate`,
    /// resolved at runtime with the same `dlsym` approach this type already uses
    /// for `AuthorizationExecuteWithPrivileges`.
    ///
    /// This is a fallback for systems where the supported `CGSession -suspend`
    /// tool no longer ships, so the caller should prefer that tool whenever it
    /// is still present.
    ///
    /// - Returns: `true` when a lock mechanism was available and invoked.
    @discardableResult
    nonisolated func lockScreen() async -> Bool {
        guard let lock = Self.lockScreenImmediate else {
            sleepyCommandLogger.error("No screen-lock mechanism available: SACLockScreenImmediate could not be resolved")
            return false
        }
        // Locking is UI-adjacent, so hop to the main actor for the call itself.
        await MainActor.run { lock() }
        return true
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
