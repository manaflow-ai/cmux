/// The function body the driver runs in a frame for `frame.evaluate` (and the
/// calls built on it): it calls `source`, a function expression, with the
/// element handles resolved to elements (`__els`) and the agent's arguments
/// (`__args`), and returns the result as JSON text, ``needsAgentSentinel``,
/// or an error envelope (`{ __cmuxError__: { code, message, name } }`).
///
/// The body runs through ``BrowserReplFrameGate/callAsyncJavaScript(_:arguments:in:frame:contentWorld:userGesture:)``,
/// whose document check comes first in the same script.
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
    public init(source: String, requiresAgent: Bool, elementsExpression: String) throws {
        text = """
        const __agent = globalThis[\(BrowserReplRuntimeBundle.agentGlobalKeyExpression)];
        if (\(requiresAgent ? "true" : "false") && !__agent) return "\(Self.needsAgentSentinel)";
        try {
          const __els = \(elementsExpression);
          const __result = await (\(source))(...__els, ...__args);
          if (__result === undefined) return "null";
          const __json = JSON.stringify(__result);
          return __json === undefined ? "null" : __json;
        } catch (e) {
          return { __cmuxError__: { code: (e && e.code) || "evaluation", message: String(e && e.message !== undefined ? e.message : e), name: (e && e.name) || "Error" } };
        }
        """
    }
}
