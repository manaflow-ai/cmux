import JavaScriptCore

/// Parses the complete body a browser will wrap in an async function, off the main actor.
/// Constructing a function parses to EOF without invoking it. Source therefore cannot
/// close the generated function and execute outside a prefixed origin guard.
public actor BrowserFunctionBodySyntax {
    /// Creates a parser whose JavaScriptCore objects never leave its executor.
    public init() {}

    /// Validates a function body and its trusted native argument names without executing it.
    public func isValid(_ body: String, arguments: [String] = []) -> Bool {
        guard let context = JSContext(),
              let constructor = context.evaluateScript("(async function () {}).constructor") else { return false }
        let function = constructor.construct(withArguments: arguments + [body])
        return context.exception == nil && function?.isObject == true
    }
}
