import Foundation

/// Decides which cloud attach panes must close after a graph publication.
///
/// A cloud pane owns no process: when the remote shell ends (`exit`, Ctrl+D)
/// the daemon drops the terminal from its graph, and the pane is the only
/// thing left holding it open. Closing is driven by the accepted graph, so the
/// rule lives here instead of inside the provider's refresh.
enum CloudTerminalPaneClosure {
    /// Panels whose bound terminal is gone from an authoritative graph.
    ///
    /// - Parameters:
    ///   - boundTerminals: local pane id -> remote terminal resource key.
    ///   - liveTerminalKeys: terminal keys in the freshly published graph.
    ///   - freshness: whether that graph is current. A stale graph means the
    ///     machine is unreachable, not that a terminal ended, so nothing closes.
    /// - Returns: panel ids in a stable order.
    static func panelsToClose(
        boundTerminals: [UUID: String],
        liveTerminalKeys: Set<String>,
        freshness: CloudVMStateFreshness
    ) -> [UUID] {
        guard freshness == .current else { return [] }
        return boundTerminals
            .filter { !liveTerminalKeys.contains($0.value) }
            .keys
            .sorted { $0.uuidString < $1.uuidString }
    }
}
