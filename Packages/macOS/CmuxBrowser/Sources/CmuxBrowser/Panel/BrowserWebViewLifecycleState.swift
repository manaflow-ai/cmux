public enum BrowserWebViewLifecycleState: String {
    case newTab = "new_tab"
    case deferredURL = "deferred_url"
    case liveVisible = "live_visible"
    case liveHidden = "live_hidden"
    case recoverableTermination = "recoverable_termination"
    case discarded
    case closing
}
