public import AppKit
import ObjectiveC

/// Stands a REPL tab's private pasteboard in for the general pasteboard while
/// WebKit runs one Copy, Cut or Paste editing command.
///
/// This is the redirect as the app ships it at 3add499
/// (`Sources/Panels/BrowserRepl/BrowserReplNativeInput.swift`), extracted
/// unchanged so its behavior can be tested: every lookup of the general
/// pasteboard by name, from any caller, returns the tab's pasteboard from the
/// moment the command starts until WebKit reports it done or `timeout`
/// passes, whichever is first.
public enum BrowserReplPasteboardRedirect {
    /// How one command ended.
    public enum Outcome: Equatable, Sendable {
        /// WebKit reported the command done.
        case completed
        /// WebKit had not reported the command done within the timeout.
        case timedOut
        /// An earlier command was still running when the timeout passed;
        /// this one did not start.
        case busy
        /// The pasteboard lookup could not be redirected.
        case unavailable
    }

    nonisolated(unsafe) private static var target: NSPasteboard?
    private static let lock = NSLock()
    @MainActor private static var installed = false
    @MainActor private static var tail: Task<Outcome, Never>?

    /// Installs the process-wide `+[NSPasteboard pasteboardWithName:]` hook
    /// once. Returns `false` when the method is missing.
    @MainActor
    public static func install() -> Bool {
        if installed { return true }
        let selector = NSSelectorFromString("pasteboardWithName:")
        guard let method = class_getClassMethod(NSPasteboard.self, selector) else { return false }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString) -> NSPasteboard
        let original = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
        let replacement: @convention(block) @Sendable (AnyObject, NSString) -> NSPasteboard = { cls, name in
            redirectTarget(forLookupOf: name as String, fromWebKit: true) ?? original(cls, selector, name)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        installed = true
        return true
    }

    /// Runs one command with `pasteboard` standing in for the general
    /// pasteboard. `invoke` starts the command and calls its argument when
    /// WebKit reports the command done.
    @MainActor
    public static func run(
        on pasteboard: NSPasteboard,
        timeout: Duration,
        invoke: @escaping @MainActor (_ done: @escaping @MainActor () -> Void) -> Void
    ) async -> Outcome {
        guard install() else { return .unavailable }
        let previous = tail
        let run = Task { @MainActor () -> Outcome in
            _ = await previous?.value
            setTarget(pasteboard)
            defer { setTarget(nil) }
            let gate = Gate()
            return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                gate.continuation = continuation
                invoke { gate.finish(.completed) }
                gate.timer = Task { @MainActor in
                    try? await ContinuousClock().sleep(for: timeout)
                    gate.finish(.timedOut)
                }
            }
        }
        tail = run
        return await run.value
    }

    /// The pasteboard a lookup of the pasteboard named `name` gets instead
    /// of the system's, or `nil` for the system's.
    public static func redirectTarget(forLookupOf name: String, fromWebKit: Bool) -> NSPasteboard? {
        lock.lock()
        defer { lock.unlock() }
        guard let target, name == NSPasteboard.Name.general.rawValue else { return nil }
        return target
    }

    private static func setTarget(_ pasteboard: NSPasteboard?) {
        lock.lock()
        target = pasteboard
        lock.unlock()
    }

    @MainActor
    private final class Gate {
        var continuation: CheckedContinuation<Outcome, Never>?
        var timer: Task<Void, Never>?

        func finish(_ outcome: Outcome) {
            timer?.cancel()
            timer = nil
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: outcome)
        }
    }
}
