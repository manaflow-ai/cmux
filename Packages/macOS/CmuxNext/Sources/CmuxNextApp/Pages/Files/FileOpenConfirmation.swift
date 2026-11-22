import AppKit
import CmuxNextPages

/// The file pages' "Open <path>?" sheet (React UIs lead review, coordinator rule): a markdown link
/// outside every granted document's folder opens only after the user confirms the resolved path.
/// The sheet shows only for a page call backed by a real gesture (`PageCallContext.userGesture`,
/// the router's 1 s window over the page view's last real key or mouse event), once per gesture
/// (the event's uptime, ``PageWebView/lastUserEventUptime``), one sheet at a time. Without one
/// nothing shows and the link is refused, so a page cannot stack or repeat sheets.
final class FileOpenConfirmation {
    private let presenter: any PageConfirmationPresenter
    /// The gesture (event uptime) the last sheet used.
    private var usedGesture: TimeInterval?
    private(set) var isShowing = false

    init(presenter: any PageConfirmationPresenter = DialogPageConfirmationPresenter()) {
        self.presenter = presenter
    }

    func confirm(_ url: URL, userGesture: Bool, gestureEvent: TimeInterval?, anchor: NSView?) async -> Bool {
        guard userGesture, let gestureEvent, !isShowing, gestureEvent != usedGesture else { return false }
        usedGesture = gestureEvent
        isShowing = true
        defer { isShowing = false }
        let confirmation = PageConfirmation(kind: .custom, name: FilePageStrings.openOutsideTitle(url.path),
                                            detail: FilePageStrings.openOutsideDetail)
        return await presenter.confirm(confirmation, anchor: anchor)
    }
}
