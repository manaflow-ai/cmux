#if canImport(UIKit)
import UIKit

/// Holds a surface's UIKit view until libghostty has finished freeing it.
///
/// `ghostty_surface_free` can run after the host view has been removed from
/// SwiftUI. libghostty still owns the raw `UIView` pointer supplied at surface
/// creation, so the view must remain alive until that call returns. This token
/// makes that ownership explicit and releases it exactly once on the main
/// actor, where UIKit objects are allowed to deinitialize.
// Safety: the surface queue only retains this token. All mutable access and
// the final UIKit release remain isolated to MainActor.
@MainActor
final class GhosttySurfaceFreeRetention: @unchecked Sendable {
    private var retainedObject: AnyObject?
    private var didRelease = false

    /// Creates a token that retains `object` until ``releaseAfterSurfaceFree``.
    init(object: AnyObject) {
        retainedObject = object
    }

    /// Releases the retained object after `ghostty_surface_free` returns.
    ///
    /// - Returns: `true` only for the first release; repeated calls are safe
    ///   and return `false`.
    @discardableResult
    func releaseAfterSurfaceFree() -> Bool {
        guard !didRelease else { return false }
        didRelease = true
        retainedObject = nil
        return true
    }
}

#endif
