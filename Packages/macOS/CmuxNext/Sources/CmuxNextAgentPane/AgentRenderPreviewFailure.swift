/// Stable render request failures translated by the app's control adapter.
package struct AgentRenderPreviewFailure: Error {
    package let code: String
    package let message: String
}
