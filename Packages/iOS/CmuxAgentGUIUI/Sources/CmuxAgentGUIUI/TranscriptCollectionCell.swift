#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI
import UIKit

final class TranscriptCollectionCell: UICollectionViewListCell {
    private(set) var rowSpacing = TranscriptRowSpacing(top: 0, bottom: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        backgroundConfiguration = .clear()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // UIHostingConfiguration swaps the list cell's managed content view,
        // which can drop the counter-flip applied at init; reassert it so the
        // cell always renders upright inside the flipped collection view.
        if contentView.transform.d != -1 {
            contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        }
    }

    private(set) var rowKind: TranscriptRowKind?

    func configure(row: TranscriptRow, spacing: TranscriptRowSpacing) {
        rowKind = row.rowKind
        rowSpacing = spacing
        contentConfiguration = UIHostingConfiguration {
            TranscriptRowContentView(row: row, spacing: rowSpacing)
        }
        .margins(.all, 0)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = row.accessibilityLabel
    }

}
#endif
