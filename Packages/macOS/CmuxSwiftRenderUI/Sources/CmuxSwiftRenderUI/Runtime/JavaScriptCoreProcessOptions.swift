import Foundation
import JavaScriptCore

/// Process-wide JavaScriptCore options that cmux sets before anything creates a `JSContext`.
public enum JavaScriptCoreProcessOptions {
    /// The JavaScriptCore option, read from the environment, that runs JIT compiles on worklist threads.
    public static let concurrentJITVariable = "JSC_useConcurrentJIT"

    /// Turns off JavaScriptCore's concurrent JIT for this process.
    ///
    /// In a hardened-runtime process with `com.apple.security.cs.allow-jit`, each JIT
    /// worklist thread maps a 512 KB arena granule that stays mapped after the thread
    /// idles out. A JS sidebar re-renders only when its data changes, so the thread
    /// exits between updates and every later burst leaves another region behind
    /// (https://github.com/manaflow-ai/cmux/issues/47871). With concurrent JIT off,
    /// compiles don't start those threads.
    ///
    /// JavaScriptCore reads its options once, when it initializes. This sets the
    /// variable, initializes JavaScriptCore, then removes the variable again so
    /// terminals cmux starts later don't inherit it. A value already in the
    /// environment is the user's choice and is left in place.
    ///
    /// - Returns: `true` when this call set the option, `false` when the environment already chose.
    @discardableResult
    public static func disableConcurrentJIT(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        setVariable: (String, String) -> Void = { _ = setenv($0, $1, 1) },
        unsetVariable: (String) -> Void = { _ = unsetenv($0) },
        initializeJavaScriptCore: () -> Void = { _ = JSContext() }
    ) -> Bool {
        guard environment[concurrentJITVariable] == nil else { return false }
        setVariable(concurrentJITVariable, "0")
        initializeJavaScriptCore()
        unsetVariable(concurrentJITVariable)
        return true
    }
}
