// cmux: the seam where the vendored AppKit views observe a notification on the main actor. Not a vendored file.
import Foundation

/// A block observer on the main queue whose handler is main-actor isolated. A post on the main
/// thread runs the handler inline, in the poster's turn (NotificationCenter runs a `.main` block
/// observer synchronously when the post is on main), as the selector-free observers of the vendored
/// views always did. Removed when this object goes.
final class MainQueueObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(_ name: Notification.Name, object: AnyObject?, center: NotificationCenter = .default,
         _ handler: @escaping @MainActor @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: .main) { note in
            // main-proof: addObserver(queue: .main) runs this block on the main queue.
            MainActor.assumeIsolated { handler(note) }
        }
    }

    deinit { center.removeObserver(token) }
}
