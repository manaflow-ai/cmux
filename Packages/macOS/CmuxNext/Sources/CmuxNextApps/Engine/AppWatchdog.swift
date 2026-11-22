import Darwin
import Foundation
import JavaScriptCore
import Synchronization

/// The 250 ms evaluation limit per app VM (spec 5.2), the idea of the old
/// custom sidebar lane's JSWatchdog: `JSContextGroupSetExecutionTimeLimit`
/// ships in JavaScriptCore but is declared only in a non-public header, so
/// it is resolved with `dlsym` and skipped when absent (the engine then
/// reports `watchdog: false` in its diagnostics). A runaway evaluation
/// terminates with an uncatchable exception; the engine then stops the VM.
nonisolated final class AppWatchdog: Sendable {
    private typealias TerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, TerminateCallback?, UnsafeMutableRawPointer?) -> Void

    private static let setLimit: SetLimit? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    static let defaultLimit: Duration = .milliseconds(250)

    private let tripped = Atomic<Bool>(false)

    /// Whether the limit fired since the last `reset()`.
    var didFire: Bool { tripped.load(ordering: .acquiring) }

    func reset() { tripped.store(false, ordering: .releasing) }

    /// Installs the limit on `context`'s group (one group per app VM).
    /// Returns whether the hard limit is active.
    @discardableResult
    func install(on context: JSContext, limit: Duration = AppWatchdog.defaultLimit) -> Bool {
        guard let setLimit = Self.setLimit else { return false }
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), seconds, { _, refcon in
            if let refcon { Unmanaged<AppWatchdog>.fromOpaque(refcon).takeUnretainedValue().tripped.store(true, ordering: .releasing) }
            return true
        }, refcon)
        return true
    }
}
