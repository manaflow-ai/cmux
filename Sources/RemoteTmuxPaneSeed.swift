import Foundation

enum RemoteTmuxPaneSeedKind: Equatable {
    case fullHistory
    case visibleRepaint
}

/// One authoritative pane snapshot and the live-stream bytes around its tmux
/// command-result boundary.
///
/// `discardedOutput` happened before tmux completed `capture-pane`, so its cells
/// are already represented by `snapshot`. `catchUpOutput` happened after that
/// boundary and must be replayed once after restoring the boundary `state`.
/// Keeping the groups typed is
/// also important for stateful escape filters: a snapshot is not a continuation
/// of an incomplete live escape sequence.
struct RemoteTmuxPaneSeed: Equatable {
    let kind: RemoteTmuxPaneSeedKind
    let discardedOutput: [Data]
    let snapshot: Data
    let catchUpOutput: [Data]
    let state: Data

    /// Compatibility projection for observers that have not registered a typed
    /// seed callback. Pre-snapshot live bytes are intentionally omitted.
    var renderedBytes: Data {
        var bytes = snapshot
        bytes.append(state)
        for chunk in catchUpOutput { bytes.append(chunk) }
        return bytes
    }
}
