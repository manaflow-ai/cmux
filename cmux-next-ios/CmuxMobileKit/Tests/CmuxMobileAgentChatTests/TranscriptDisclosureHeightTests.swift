#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// A tool row measured collapsed, then opened, kept its revision (the row's content did not
/// change, only the disclosure), so the cell's sizing shortcut returned the collapsed height
/// and the open output was clipped under the next row. A disclosure change now makes every
/// earlier measurement no shortcut, so a cell showing the row again measures it.
@MainActor
@Suite struct TranscriptDisclosureHeightTests {
    @Test func aDisclosureChangeDropsTheMeasuredShortcut() {
        let layout = ChatTranscriptLayout()
        layout.setItems([.init(id: "tool-1", revision: 3, gap: 8, estimate: 40)])
        let measured = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        measured.size = CGSize(width: 360, height: 44)
        _ = layout.shouldInvalidateLayout(forPreferredLayoutAttributes: measured, withOriginalAttributes: measured)
        #expect(layout.knownHeight(of: "tool-1")?.height == 44, "collapsed, measured: a shortcut")

        layout.disclosureRevision += 1
        #expect(layout.knownHeight(of: "tool-1") == nil, "opened: the collapsed height is no shortcut")

        measured.size = CGSize(width: 360, height: 220)
        _ = layout.shouldInvalidateLayout(forPreferredLayoutAttributes: measured, withOriginalAttributes: measured)
        #expect(layout.knownHeight(of: "tool-1")?.height == 220, "measured open: its own shortcut")
    }
}
#endif
