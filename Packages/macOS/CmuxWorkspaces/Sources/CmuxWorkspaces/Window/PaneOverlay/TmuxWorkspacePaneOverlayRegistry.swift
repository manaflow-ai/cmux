public import AppKit
import ObjectiveC

/// Per-window owner of ``TmuxWorkspacePaneOverlayController`` instances. Resolves
/// (and, when requested, lazily creates) the one controller attached to a given
/// `NSWindow`, storing it as an associated object on the window exactly as the
/// former app-target `tmuxWorkspacePaneWindowOverlayController(for:createIfNeeded:)`
/// free function did.
///
/// Constructed once at the composition root over the app-side
/// ``TmuxWorkspacePaneOverlayTarget``; `ContentView`/`AppDelegate` forward their
/// `controller(for:createIfNeeded:)?.update(state:)` calls here.
@MainActor
public final class TmuxWorkspacePaneOverlayRegistry {
    private static var associatedObjectKey: UInt8 = 0

    private let target: any TmuxWorkspacePaneOverlayTarget

    /// Creates the registry over the app-side overlay seam.
    public init(target: any TmuxWorkspacePaneOverlayTarget) {
        self.target = target
    }

    /// Returns the controller attached to `window`, creating one when
    /// `createIfNeeded` is `true` and none exists yet. Returns `nil` when no
    /// controller exists and `createIfNeeded` is `false`.
    public func controller(
        for window: NSWindow,
        createIfNeeded: Bool
    ) -> TmuxWorkspacePaneOverlayController? {
        if let existing = objc_getAssociatedObject(
            window,
            &Self.associatedObjectKey
        ) as? TmuxWorkspacePaneOverlayController {
            return existing
        }
        guard createIfNeeded else { return nil }
        let controller = TmuxWorkspacePaneOverlayController(window: window, target: target)
        objc_setAssociatedObject(
            window,
            &Self.associatedObjectKey,
            controller,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return controller
    }
}
