import Foundation
import Testing
@testable import CMUXMobileCore

/// The grid-content hash is the divergence detector: the producer stamps the
/// hash of its authoritative full grid onto every frame, and the consumer
/// recomputes it from its own applied grid to decide whether a delta silently
/// missed a row. These tests pin the two properties that make that work: the
/// hash is content-addressed and process-stable, and a dropped clear is
/// detected.

@Test func gridContentHashIsContentAddressedAndStable() throws {
    func grid(_ text: String) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "terminal-a", stateSeq: 1, columns: 8, rows: 3, text: text
        )
    }

    // Same content, two independent constructions -> identical hash. This is
    // the cross-process guarantee: Swift's seeded `Hasher` could not provide it.
    #expect(try grid("alpha\nbeta\n").gridContentHash() ==
            grid("alpha\nbeta\n").gridContentHash())

    // Any content change moves the hash.
    #expect(try grid("alpha\nbeta\n").gridContentHash() !=
            grid("alpha\nbetaX\n").gridContentHash())

    // A blanked row is distinct from a populated one (the core blank-out case).
    #expect(try grid("alpha\n\n").gridContentHash() !=
            grid("alpha\nbeta\n").gridContentHash())

    // Dimensions are part of the identity.
    let wide = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a", stateSeq: 1, columns: 9, rows: 3, text: "alpha\nbeta\n"
    )
    #expect(try grid("alpha\nbeta\n").gridContentHash() != wide.gridContentHash())
}

@Test func gridContentHashFromPrecomputedSignaturesMatches() throws {
    // The producer hashes from already-computed rowSignatures() to avoid walking
    // the grid twice; that must equal the convenience form the consumer uses.
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a", stateSeq: 1, columns: 8, rows: 3, text: "alpha\nbeta\n"
    )
    #expect(frame.gridContentHash(rowSignatures: frame.rowSignatures()) == frame.gridContentHash())
}

@Test func gridContentHashIgnoresCursorPosition() throws {
    let a = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a", stateSeq: 1, columns: 8, rows: 3,
        text: "alpha\nbeta\n", cursor: .init(row: 0, column: 0)
    )
    let b = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a", stateSeq: 1, columns: 8, rows: 3,
        text: "alpha\nbeta\n", cursor: .init(row: 2, column: 4)
    )
    // Detect CONTENT divergence, not cursor movement.
    #expect(a.gridContentHash() == b.gridContentHash())
}

@Test func divergenceDetectsADroppedClear() throws {
    // Authoritative grid: row 2 was blanked. Applied grid: the delta that should
    // have cleared row 2 was dropped, so it still shows stale "ghi".
    let authoritative = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a", stateSeq: 7, columns: 8, rows: 3, text: "alpha\nDEF\n"
    )
    let appliedStale = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a", stateSeq: 7, columns: 8, rows: 3, text: "alpha\nDEF\nghi"
    )

    let received = authoritative.stampingGridHash(authoritative.gridContentHash())

    // Consumer applied a stale grid -> divergence detected -> keyframe requested.
    #expect(received.divergesFromAppliedGrid(hash: appliedStale.gridContentHash()) == true)
    // Consumer applied the correct grid -> no false positive, no keyframe churn.
    #expect(received.divergesFromAppliedGrid(hash: authoritative.gridContentHash()) == false)
}

@Test func gridHashRoundTripsAndIsBackCompatible() throws {
    let base = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a", stateSeq: 3, columns: 8, rows: 3, text: "alpha\nbeta\n"
    )

    // Legacy producer: no hash stamped -> nil, and the detector never demands a
    // keyframe it cannot verify.
    #expect(base.gridHash == nil)
    #expect(base.divergesFromAppliedGrid(hash: 0xDEAD_BEEF) == false)

    // Stamped hash survives a JSON round-trip.
    let stamped = base.stampingGridHash(base.gridContentHash())
    let decoded = try MobileTerminalRenderGridFrame.decode(JSONEncoder().encode(stamped))
    #expect(decoded.gridHash == base.gridContentHash())
    #expect(decoded == stamped)

    // The wire key is omitted entirely when nil (no `grid_hash: null`), so old
    // and new readers both accept legacy frames.
    let legacyJSON = try JSONEncoder().encode(base)
    let object = try JSONSerialization.jsonObject(with: legacyJSON) as? [String: Any]
    #expect(object?["grid_hash"] == nil)
}
