import Darwin
import Foundation
import JavaScriptCore

/// Bounds every JavaScript run on a REPL session's thread.
///
/// JavaScript runs on the session's one thread, so a synchronous infinite
/// loop would hold that thread forever and nothing queued behind it (the
/// timeout's cleanup, the next cell, `close()`) could run. JavaScriptCore's
/// `JSContextGroupSetExecutionTimeLimit` calls a callback on the JS thread
/// once a script has run for `checkInterval` without returning (in practice
/// JavaScriptCore checks every second or two); the callback returns `true` to
/// terminate that script with an uncatchable exception.
///
/// The session enters JavaScript only through ``run(evalID:_:)`` (a cell,
/// a driver result, a timer, an event, a cancel), naming the cell that is
/// running then. A run is terminated when the session asks for it (a cell
/// timed out), once the session closed (for good: nothing clears that), or
/// when it has gone on for `callbackTimeLimit` while the cell it started
/// under is no longer running, or it started under none. Agent code can
/// start work outside a cell (timers, event handlers, promise jobs a later
/// run drains), so every run is bounded, not only cells.
///
/// Runs outside a cell also share a time credit, so a stream of callbacks
/// each under `callbackTimeLimit` cannot hold the thread: the credit holds
/// at most `callbackTimeLimit`, refills at `callbackShare` of wall time, and
/// pays for every run that starts outside a cell; a run gets at most the
/// credit left when it starts. The session holds callbacks back while the
/// credit is in debt (``isInCallbackDebt``) and asks ``timeUntilCredit``
/// when to try again.
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
    private var closed = false
    private var terminatedScript = false
    /// How long a run outside its cell may go on.
    let callbackTimeLimit: Duration
    /// The cell running now, as the session last reported it.
    private var currentEvalID: Int?
    /// The outermost run in progress: when it started and under which cell.
    private var depth = 0
    private var runStart = ContinuousClock.now
    private var runEvalID: Int?
    /// How long the outermost run may go on once it is outside its cell.
    private var runLimit: Duration
    /// Whether the outermost run started outside a cell and pays from the credit.
    private var runPaysCredit = false
    /// Set when the limit (not a request or close) terminated a script.
    private var limitTerminated = false
    /// The callback credit as of `creditUpdatedAt`; negative is debt.
    private var credit: Duration
    private var creditUpdatedAt = ContinuousClock.now

    /// The share of wall time callbacks outside a cell may use over time.
    static let callbackShare = 0.1

    init(callbackTimeLimit: Duration) {
        self.callbackTimeLimit = callbackTimeLimit
        self.runLimit = callbackTimeLimit
        self.credit = callbackTimeLimit
    }

    /// The credit at `now`, refilled since it last changed. Call with `lock` held.
    private func creditLocked(at now: ContinuousClock.Instant) -> Duration {
        min(callbackTimeLimit, credit + (now - creditUpdatedAt) * Self.callbackShare)
    }

    /// Whether runs outside a cell have used more than their credit; the
    /// session then holds callbacks back.
    var isInCallbackDebt: Bool {
        lock.withLock { creditLocked(at: .now) < .zero }
    }

    /// How long until the credit is out of debt (zero when it is).
    var timeUntilCredit: Duration {
        lock.withLock {
            let now = creditLocked(at: .now)
            guard now < .zero else { return .zero }
            return (Duration.zero - now) * (1 / Self.callbackShare) + .milliseconds(1)
        }
    }

    /// Whether the limit terminated a script since the last call, and clears it.
    func takeLimitTermination() -> Bool {
        lock.withLock {
            defer { limitTerminated = false }
            return limitTerminated
        }
    }

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

    /// Whether the running script is to be terminated (a timeout asked, or
    /// the session closed): native work on the thread checks it to stop
    /// early too.
    var isTerminationRequested: Bool {
        lock.withLock { terminationRequested }
    }

    /// Ends a request; never one `close()` made.
    func clearTermination() {
        lock.withLock { terminationRequested = closed }
    }

    /// Every script that runs from now on is terminated.
    func close() {
        lock.withLock {
            closed = true
            terminationRequested = true
        }
    }

    /// Records the cell that runs now (`nil` when none).
    func setCurrentEval(_ id: Int?) {
        lock.withLock { currentEvalID = id }
    }

    /// Runs `body`, which enters the context, as one run under cell `evalID`
    /// (the cell running when it started, or `nil`). Nested runs belong to
    /// the outermost one.
    func run<T>(evalID: Int?, _ body: () -> T) -> T {
        lock.withLock {
            if depth == 0 {
                let now = ContinuousClock.now
                runStart = now
                runEvalID = evalID
                runPaysCredit = evalID == nil || evalID != currentEvalID
                if runPaysCredit {
                    credit = creditLocked(at: now)
                    creditUpdatedAt = now
                    runLimit = max(.zero, min(callbackTimeLimit, credit))
                } else {
                    runLimit = callbackTimeLimit
                }
            }
            depth += 1
        }
        defer {
            lock.withLock {
                depth -= 1
                if depth == 0, runPaysCredit {
                    // Refilled while it ran, less what it used.
                    let now = ContinuousClock.now
                    credit = creditLocked(at: now) - (now - runStart)
                    creditUpdatedAt = now
                }
            }
        }
        return body()
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
        lock.withLock {
            if terminationRequested { return true }
            guard depth > 0, runEvalID == nil || runEvalID != currentEvalID else { return false }
            guard ContinuousClock.now - runStart >= runLimit else { return false }
            limitTerminated = true
            return true
        }
    }
}
