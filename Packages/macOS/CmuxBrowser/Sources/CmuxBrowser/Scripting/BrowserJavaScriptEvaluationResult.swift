/// Distinguishes a missing WebKit callback from JavaScript errors that returned normally.
public enum BrowserJavaScriptEvaluationResult {
    case success(Any?)
    case failure(String)
    case timedOut
}
