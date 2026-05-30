// SPDX-License-Identifier: MIT

import Foundation
import ObjectiveC

extension OutputSubscription {
    /// Storage key for the lifetime-retain associated object.
    ///
    /// We use a single `UInt8` constant whose address is the
    /// `objc_setAssociatedObject` key. Using an associated object keeps
    /// the lifetime helper purely additive — no change to the public
    /// stored-property layout in ``OutputSubscription``.
    private static var lifetimeKey: UInt8 = 0

    /// Retain ``obj`` for the lifetime of this subscription.
    ///
    /// The Phase 2 cells/raw subscription wiring calls this after
    /// ``SurfaceProvider/observeClose(_:onClose:)`` returns its lifetime
    /// token so the observer stays attached until the subscription
    /// terminates. The retained object is dropped when this
    /// ``OutputSubscription`` itself is deallocated (the typical path
    /// after ``cancel()`` runs and any caller releases the
    /// subscription).
    ///
    /// Subsequent calls overwrite the previously attached lifetime —
    /// only one token is retained at a time.
    ///
    /// - Parameter obj: The lifetime token to retain.
    public func attachLifetime(_ obj: AnyObject) {
        objc_setAssociatedObject(
            self,
            &OutputSubscription.lifetimeKey,
            obj,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
