import Darwin
import Foundation
import JavaScriptCore

/// Terminates a REPL context's running script on request.
///
/// JavaScript runs on the session's one thread, so a synchronous infinite
/// loop would hold that thread forever and nothing queued behind it (the
/// timeout's cleanup, the next cell, `close()`) could run. JavaScriptCore's
/// `JSContextGroupSetExecutionTimeLimit` calls a callback on the JS thread
/// once a script has run for `checkInterval` without returning (in practice
/// JavaScriptCore checks every second or two); the callback returns `true` to
/// terminate that script with an uncatchable exception. The session asks for termination when a cell times out or the
/// session closes, and clears the request once the JS thread is free again.
///
/// The function is exported by JavaScriptCore but declared in a non-public
/// header, so it is resolved with `dlsym`, as `JSWatchdog` in
/// CmuxSwiftRenderUI does.
final class BrowserReplWatchdog: @unchecked Sendable {
    private typealias TerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimitFunction = @convention(c) (
        JSContextGroupRef?, Double, TerminateCallback?, UnsafeMutableRawPointer?
    ) -> Void

    private static let setLimit: SetLimitFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "JSContextGroupSetExecutionTimeLimit") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetLimitFunction.self)
    }()

    /// How often a long-running script is checked for a termination request.
    static let checkInterval: Double = 0.25

    private let lock = NSLock()
    private var terminationRequested = false
    private var terminatedScript = false

    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    /// Installs the check on `context`'s group. The context retains the
    /// watchdog, so the callback's pointer stays valid as long as the context
    /// can run scripts. Returns whether JavaScriptCore supports termination.
    @discardableResult
    func install(on context: JSContext) -> Bool {
        guard let setLimit = Self.setLimit else { return false }
        objc_setAssociatedObject(context, &Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN)
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        setLimit(group, Self.checkInterval, Self.callback, Unmanaged.passUnretained(self).toOpaque())
        return true
    }

    /// Terminates the script when asked to; otherwise re-arms the limit,
    /// because JavaScriptCore checks a running script once per arming and a
    /// callback that returns false must set the limit again to be asked again.
    private static let callback: TerminateCallback = { context, info in
        guard let info else { return false }
        let watchdog = Unmanaged<BrowserReplWatchdog>.fromOpaque(info).takeUnretainedValue()
        if watchdog.shouldTerminate {
            watchdog.lock.withLock { watchdog.terminatedScript = true }
            return true
        }
        if let context, let setLimit = BrowserReplWatchdog.setLimit {
            setLimit(JSContextGetGroup(context), BrowserReplWatchdog.checkInterval, BrowserReplWatchdog.callback, info)
        }
        return false
    }

    /// Whether termination is supported in this process.
    static var isSupported: Bool { setLimit != nil }

    /// The script running now, and any that runs past `checkInterval` before
    /// `clearTermination()`, is terminated.
    func requestTermination() {
        lock.withLock { terminationRequested = true }
    }

    func clearTermination() {
        lock.withLock { terminationRequested = false }
    }

    /// After a termination JavaScriptCore can still hold the termination
    /// for the next entry into the context, which then ends before running
    /// anything. Call this on the JS thread before running a script; it runs
    /// one empty script to take that termination, once per termination.
    func absorbTermination(in context: JSContext) {
        let terminated: Bool = lock.withLock {
            defer { terminatedScript = false }
            return terminatedScript
        }
        guard terminated else { return }
        context.evaluateScript("void 0")
        context.exception = nil
    }

    private var shouldTerminate: Bool {
        lock.withLock { terminationRequested }
    }
}
