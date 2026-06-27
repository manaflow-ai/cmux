#if DEBUG
import AppKit

extension Optional where Wrapped == NSResponder {
    /// DEBUG-only focus-log summary for the feed inline editor: `"nil"` for a
    /// missing responder, otherwise the responder's concrete type name.
    ///
    /// Mirrors the former app-side `feedDebugResponderSummary` helper exactly so
    /// the relocated editor emits byte-identical `feed.editor.*` log lines.
    var feedInlineResponderDebugSummary: String {
        guard let self else { return "nil" }
        return String(describing: type(of: self))
    }
}
#endif
