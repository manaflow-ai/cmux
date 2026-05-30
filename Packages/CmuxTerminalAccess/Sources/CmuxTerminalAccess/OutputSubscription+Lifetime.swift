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

    /// Storage key for the ``ringOldestSeq()`` provider closure.
    ///
    /// Same associated-object trick as ``lifetimeKey`` so the Phase 2
    /// SSE layer can read "what is the oldest seq still retained in
    /// my per-subscriber ring" without changing the public stored-
    /// property layout in ``OutputSubscription``.
    private static var ringOldestSeqKey: UInt8 = 0

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

    /// Holder for the ``attachRingOldestSeq(_:)`` provider closure.
    ///
    /// `objc_setAssociatedObject` only retains `AnyObject`, so we wrap
    /// the `@Sendable` closure in a thin class to keep the storage
    /// boxed.
    private final class RingOldestSeqProvider {
        let provide: @Sendable () -> UInt64
        init(_ provide: @escaping @Sendable () -> UInt64) {
            self.provide = provide
        }
    }

    /// Attach a closure that returns the seq of the oldest event still
    /// retained in this subscription's per-subscriber ring.
    ///
    /// The Phase 2 SSE responder calls ``ringOldestSeq()`` after a
    /// successful subscribe to decide whether a `Last-Event-ID` resume
    /// fell below the ring (D6 — synthetic ``: gap`` comment) or
    /// inside the ring (D6 — replay from `resume + 1`).
    ///
    /// - Parameter provider: Sendable closure invoked on every
    ///   ``ringOldestSeq()`` call; the closure should weakly reference
    ///   the ring so the subscription doesn't leak the ring after
    ///   ``cancel()``.
    public func attachRingOldestSeq(
        _ provider: @escaping @Sendable () -> UInt64
    ) {
        objc_setAssociatedObject(
            self,
            &OutputSubscription.ringOldestSeqKey,
            RingOldestSeqProvider(provider),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// Returns the seq of the oldest retained event in the per-
    /// subscriber ring, or 0 when no provider is attached. Callers
    /// should treat 0 as "ring is empty" and skip the gap comment.
    public func ringOldestSeq() -> UInt64 {
        let stored = objc_getAssociatedObject(
            self,
            &OutputSubscription.ringOldestSeqKey
        )
        if let box = stored as? RingOldestSeqProvider {
            return box.provide()
        }
        return 0
    }
}
