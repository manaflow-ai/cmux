// cmux: a click on a picture in the message box opens it large, a double click opens nothing (issue 51939).
import AppKit

/// The message box's pending picture open. A double click's first release is a single click (clickCount 1), so a
/// click only schedules its open; the next press in the field (the double click's second) cancels it before the
/// double-click interval ends. The pane's ``ChatController`` owns one; the field reaches it through its
/// `onPress` and `onOpenDraftPicture` callbacks (PaneHost.swift).
@MainActor final class DraftPictureClick {
    /// How long a click waits for a second press; nil is the user's double-click interval. Tests shorten it.
    var delay: TimeInterval?
    private var pending: Task<Void, Never>?

    /// Opens with `open` once the interval passes with no press in between (replacing an open still pending).
    func schedule(_ open: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let delay = delay ?? NSEvent.doubleClickInterval
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pending = nil
            open()
        }
    }

    /// A press in the field: whatever click was waiting does not open.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    var isPending: Bool { pending != nil }
}
