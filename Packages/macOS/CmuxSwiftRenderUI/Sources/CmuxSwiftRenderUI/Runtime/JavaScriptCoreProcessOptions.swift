import Foundation
import JavaScriptCore

/// Sets process-wide JavaScriptCore options before anything in the process creates a `JSContext`.
///
/// Construct one at a process entry point. The environment and the side effects
/// are injected so the order of operations can be tested without touching the
/// test process's own JavaScriptCore.
public struct JavaScriptCoreProcessOptions {
    /// The JavaScriptCore option, read from the environment, that runs JIT compiles on worklist threads.
    public static let concurrentJITVariable = "JSC_useConcurrentJIT"

    private let environment: [String: String]
    private let setVariable: (String, String) -> Void
    private let unsetVariable: (String) -> Void
    private let initializeJavaScriptCore: () -> Void

    /// Creates options that act on the given environment snapshot and side effects.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        setVariable: @escaping (String, String) -> Void = { _ = setenv($0, $1, 1) },
        unsetVariable: @escaping (String) -> Void = { _ = unsetenv($0) },
        initializeJavaScriptCore: @escaping () -> Void = { _ = JSContext() }
    ) {
        self.environment = environment
        self.setVariable = setVariable
        self.unsetVariable = unsetVariable
        self.initializeJavaScriptCore = initializeJavaScriptCore
    }

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
    public func disableConcurrentJIT() -> Bool {
        let variable = Self.concurrentJITVariable
        guard environment[variable] == nil else { return false }
        setVariable(variable, "0")
        initializeJavaScriptCore()
        unsetVariable(variable)
        return true
    }
}
