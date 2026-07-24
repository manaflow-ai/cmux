import CMUXMobileCore
import Foundation

/// Tracks which render-grid anchor each mobile connection negotiated on
/// `mobile.events.subscribe`, so the render observer produces only the payload
/// variants that have a live consumer and the event fan-out delivers each
/// connection its own contract:
///
/// - `.viewport` (v1): rows follow the Mac's live scroll position; the phone
///   mirrors it and forwards scroll gestures as RPCs.
/// - `.screen` (v2): rows anchor to the active area; the phone owns its local
///   viewport/scrollback and primary-screen scrolling never round-trips.
///
/// Registered at subscribe time, replaced idempotently, and removed when the
/// connection closes. Safe from any actor/queue.
enum MobileTerminalRenderGridAnchorRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var anchorsByConnectionID:
        [UUID: MobileTerminalRenderGridFrame.Anchor] = [:]

    static func set(_ anchor: MobileTerminalRenderGridFrame.Anchor, connectionID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        anchorsByConnectionID[connectionID] = anchor
    }

    static func remove(connectionID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        anchorsByConnectionID.removeValue(forKey: connectionID)
    }

    /// The anchor this connection negotiated; `.viewport` when it never
    /// subscribed to render-grid events or predates anchor negotiation.
    static func anchor(connectionID: UUID) -> MobileTerminalRenderGridFrame.Anchor {
        lock.lock()
        defer { lock.unlock() }
        return anchorsByConnectionID[connectionID] ?? .viewport
    }

    /// The set of anchors with at least one registered connection. The
    /// producer skips building payload variants nobody consumes; an empty set
    /// (subscribers predating anchor negotiation) means viewport-only.
    static func activeAnchors() -> Set<MobileTerminalRenderGridFrame.Anchor> {
        lock.lock()
        defer { lock.unlock() }
        return Set(anchorsByConnectionID.values)
    }

    #if DEBUG
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        anchorsByConnectionID.removeAll()
    }
    #endif
}
