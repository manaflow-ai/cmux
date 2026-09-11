#if canImport(AppKit)

import AppKit
import Testing
@testable import CmuxAppKitSupportUI

@Suite struct ArrowlessPopoverPositioningTests {
    private let button = CGRect(x: 6, y: 0, width: 22, height: 22)

    @Test func defaultAnchorKeepsTheButtonWidth() {
        let rect = ArrowlessPopoverPositioning.rect(for: button, preferredEdge: .maxY, detachedGap: 4)
        #expect(rect.minX == 6)
        #expect(rect.width == 22)
        #expect(rect.height == 9)
    }

    @Test func anchorWidthWidensFromTheLeadingEdgeAboveAndBelow() {
        for edge in [NSRectEdge.maxY, .minY] {
            let rect = ArrowlessPopoverPositioning.rect(for: button, preferredEdge: edge, detachedGap: 4, anchorWidth: 320)
            #expect(rect.minX == 6)
            #expect(rect.width == 320)
        }
    }

    @Test func anchorWidthNeverShrinksBelowTheButton() {
        let rect = ArrowlessPopoverPositioning.rect(for: button, preferredEdge: .maxY, detachedGap: 4, anchorWidth: 10)
        #expect(rect.width == 22)
    }

    @Test func sideEdgesIgnoreAnchorWidth() {
        let rect = ArrowlessPopoverPositioning.rect(for: button, preferredEdge: .maxX, detachedGap: 4, anchorWidth: 320)
        #expect(rect.width == 9)
        #expect(rect.height == 22)
    }
}

#endif
