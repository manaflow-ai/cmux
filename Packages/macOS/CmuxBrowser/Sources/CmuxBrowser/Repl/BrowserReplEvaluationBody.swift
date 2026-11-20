import JavaScriptCore

/// The function body the driver runs in a frame for `frame.evaluate` (and the
/// calls built on it): it calls `source`, a function expression, with the
/// element handles resolved to elements (`__els`) and the agent's arguments
/// (`__args`), and returns the result as JSON text, ``needsAgentSentinel``,
/// or an error envelope (`{ __cmuxError__: { code, message, name } }`).
///
/// The body runs through ``BrowserReplFrameGate/callAsyncJavaScript(_:arguments:in:frame:contentWorld:userGesture:)``,
/// whose document check comes first in the same script. WebKit builds that
/// script as text (`(async function (arguments) {` + body + `})`), evaluates
/// it, then calls the function, so text that closes the expression it was
/// put in would run before the check, in whatever document the frame shows.
/// So `source` must be one expression on its own: it goes in as the default
/// value of a function's only parameter, and JavaScriptCore's `Function`
/// constructor, which parses a parameter list on its own and refuses one
/// that ends before its text does, compiles that parameter list first
/// (nothing runs). Text that passes can at most add parameters to that
/// function; it cannot reach the check's scope or the script around it.
public struct BrowserReplEvaluationBody: Sendable {
    /// Returned when the body needs the page agent and the frame has none.
    public static let needsAgentSentinel = "__cmuxNeedsAgent__"

    /// The function body (`callAsyncJavaScript` source).
    public let text: String

    /// - Parameters:
    ///   - source: the function expression to call.
    ///   - requiresAgent: whether the body needs the page agent in its world.
    ///   - elementsExpression: the driver's own expression for the element
    ///     list (`__agent` is the page agent).
    /// - Throws: `invalid` when `source` is not one expression on its own.
    @MainActor
    public init(source: String, requiresAgent: Bool, elementsExpression: String) throws {
        let parameter = "__cmuxFunction = (\n\(source)\n)"
        try Self.checkParameterList(parameter)
        text = """
        const __agent = globalThis[\(BrowserReplRuntimeBundle.agentGlobalKeyExpression)];
        if (\(requiresAgent ? "true" : "false") && !__agent) return "\(Self.needsAgentSentinel)";
        try {
          const __els = \(elementsExpression);
          const __function = (function (\(parameter)
        ) {
        return __cmuxFunction;
        })();
          const __result = await __function(...__els, ...__args);
          if (__result === undefined) return "null";
          const __json = JSON.stringify(__result);
          return __json === undefined ? "null" : __json;
        } catch (e) {
          return { __cmuxError__: { code: (e && e.code) || "evaluation", message: String(e && e.message !== undefined ? e.message : e), name: (e && e.name) || "Error" } };
        }
        """
    }

    /// Parses only; compiles nothing the page sees and runs nothing.
    @MainActor private static let parser = JSContext()

    /// Throws `invalid` unless `parameter` is a parameter list on its own.
    @MainActor
    private static func checkParameterList(_ parameter: String) throws {
        guard let parser, let function = parser.objectForKeyedSubscript("Function") else {
            throw BrowserReplDriverError(code: "unsupported", message: "The function to evaluate cannot be checked: JavaScriptCore is unavailable")
        }
        parser.exception = nil
        _ = function.construct(withArguments: [parameter, ""])
        if let exception = parser.exception {
            parser.exception = nil
            throw BrowserReplDriverError(
                code: "invalid",
                message: "The function to evaluate must be one expression on its own: \(exception.toString() ?? "it does not parse")"
            )
        }
    }
}
