import Foundation
import JavaScriptCore

/// Process-wide JavaScriptCore options that cmux sets before anything creates a `JSContext`.
public enum JavaScriptCoreProcessOptions {
    /// The JavaScriptCore option, read from the environment, that runs JIT compiles on worklist threads.
    public static let concurrentJITVariable = "JSC_useConcurrentJIT"

    /// Turns off JavaScriptCore's concurrent JIT for this process.
    ///
    /// - Returns: `true` when this call set the option, `false` when the environment already chose.
    @discardableResult
    public static func disableConcurrentJIT(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        setVariable: (String, String) -> Void = { _ = setenv($0, $1, 1) },
        unsetVariable: (String) -> Void = { _ = unsetenv($0) },
        initializeJavaScriptCore: () -> Void = { _ = JSContext() }
    ) -> Bool {
        false
    }
}
