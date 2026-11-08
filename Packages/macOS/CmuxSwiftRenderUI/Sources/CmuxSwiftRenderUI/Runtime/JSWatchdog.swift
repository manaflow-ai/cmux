import Darwin
import Foundation
import JavaScriptCore

/// Hard execution-time limit for a JS context group.
///
/// `JSContextGroupSetExecutionTimeLimit` ships in JavaScriptCore but is
/// declared in a non-public header (`JSContextRefPrivate.h`), so it is
/// resolved at runtime with `dlsym` and skipped when absent. With the limit
/// installed, a runaway evaluation (author `while(true)`) terminates with a
/// catchable exception after `seconds`; without it, the soft guards remain
/// (the prelude's effect-loop bound and the scene-op value diffs).
enum JSWatchdog {
    private typealias TerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimitFn = @convention(c) (
        JSContextGroupRef?, Double, TerminateCallback?, UnsafeMutableRawPointer?
    ) -> Void

    private static let setLimit: SetLimitFn? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "JSContextGroupSetExecutionTimeLimit") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetLimitFn.self)
    }()

    /// Installs the limit on `context`'s group. Returns whether the hard
    /// watchdog is active.
    @discardableResult
    static func install(on context: JSContext, seconds: Double) -> Bool {
        guard let setLimit else { return false }
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        setLimit(group, seconds, { _, _ in true }, nil)
        return true
    }
}
