import Foundation

final class FeedKeyboardFocusBridgeCoordinator {
    var onHostChange: (FeedKeyboardFocusView?) -> Void
    weak var host: FeedKeyboardFocusView?
    var lastFocusRequest: Int

    init(
        onHostChange: @escaping (FeedKeyboardFocusView?) -> Void,
        focusRequest: Int
    ) {
        self.onHostChange = onHostChange
        self.lastFocusRequest = focusRequest
    }

    func attach(_ host: FeedKeyboardFocusView) {
        guard self.host !== host else { return }
        self.host = host
        onHostChange(host)
    }

    func detach(_ host: FeedKeyboardFocusView) {
        guard self.host === host else { return }
        self.host = nil
        onHostChange(nil)
    }
}
