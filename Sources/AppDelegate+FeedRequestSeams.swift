import CmuxNotifications
import Foundation

/// App-side conformer for the `CmuxNotifications` ``FeedRequestSocketLineInvoking``
/// seam. Forwards each JSON-RPC line built by ``FeedRequestRouter`` to the
/// app-target `TerminalController.shared.handleSocketLine(_:)` singleton, which
/// the package must not import.
///
/// Holds no `AppDelegate` reference (the only collaborator is the
/// `TerminalController` singleton), so there is no retain cycle; the router
/// strong-refs this adapter and `AppDelegate` strong-refs the router. The
/// invoke discards the handler result, mirroring the legacy
/// `_ = controller.handleSocketLine(line)`.
@MainActor
final class FeedRequestSocketAdapter: FeedRequestSocketLineInvoking {
    func invoke(line: String) {
        _ = TerminalController.shared.handleSocketLine(line)
    }
}
