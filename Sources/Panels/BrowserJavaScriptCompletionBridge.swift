/// Delivers a WebKit JavaScript result on the actor promised by the browser
/// focus repository, even when the Objective-C callback arrives off-actor.
struct BrowserJavaScriptCompletionBridge: Sendable {
    /// Schedules one raw WebKit result/error pair on the main actor.
    func deliver(
        result: Any?,
        error: (any Error)?,
        to completion: @escaping @MainActor (Any?, (any Error)?) -> Void
    ) {
        Task { @MainActor in
            completion(result, error)
        }
    }
}
