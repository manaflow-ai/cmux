import CMUXMobileCore
import Foundation
import os

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
/// connection closes. Safe from any actor/queue. Constructable for tests; the
/// process-wide instance lives alongside `MobileHostConnectionRegistry.shared`,
/// whose connection lifecycle drives this registry's entries.
final class MobileTerminalRenderGridAnchorRegistry: Sendable {
    static let shared = MobileTerminalRenderGridAnchorRegistry()

    private let anchorsByConnectionID =
        OSAllocatedUnfairLock<[UUID: MobileTerminalRenderGridFrame.Anchor]>(initialState: [:])

    func set(_ anchor: MobileTerminalRenderGridFrame.Anchor, connectionID: UUID) {
        anchorsByConnectionID.withLock { $0[connectionID] = anchor }
    }

    func remove(connectionID: UUID) {
        _ = anchorsByConnectionID.withLock { $0.removeValue(forKey: connectionID) }
    }

    /// The anchor this connection negotiated; `.viewport` when it never
    /// subscribed to render-grid events or predates anchor negotiation.
    func anchor(connectionID: UUID) -> MobileTerminalRenderGridFrame.Anchor {
        anchorsByConnectionID.withLock { $0[connectionID] ?? .viewport }
    }

    /// The set of anchors with at least one registered connection. The
    /// producer skips building payload variants nobody consumes; an empty set
    /// (subscribers predating anchor negotiation) means viewport-only.
    func activeAnchors() -> Set<MobileTerminalRenderGridFrame.Anchor> {
        anchorsByConnectionID.withLock { Set($0.values) }
    }
}

/// Tracks which mobile connections opted into zlib event-frame compression
/// (`event_compression: "deflate"` at subscribe). Same lifecycle as the
/// anchor registry: set at subscribe, removed when the connection closes. A
/// sender must never emit a compressed frame to a connection not in here.
final class MobileHostEventCompressionRegistry: Sendable {
    static let shared = MobileHostEventCompressionRegistry()

    private let deflateConnectionIDs =
        OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    func set(deflateEnabled: Bool, connectionID: UUID) {
        deflateConnectionIDs.withLock {
            if deflateEnabled {
                $0.insert(connectionID)
            } else {
                $0.remove(connectionID)
            }
        }
    }

    func isDeflateEnabled(connectionID: UUID) -> Bool {
        deflateConnectionIDs.withLock { $0.contains(connectionID) }
    }

    func remove(connectionID: UUID) {
        _ = deflateConnectionIDs.withLock { $0.remove(connectionID) }
    }
}
