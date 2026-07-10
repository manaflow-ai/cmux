#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI
import UIKit

final class TranscriptCollectionCell: UICollectionViewListCell {
    private var measuredHeight: CGFloat?

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

    func configure(row: TranscriptRow, measuredHeight: CGFloat) {
        self.measuredHeight = measuredHeight
        contentConfiguration = UIHostingConfiguration {
            TranscriptRowContentView(row: row)
        }
        .margins(.all, 0)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = row.accessibilityLabel
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        if let measuredHeight {
            attributes.size.height = measuredHeight
        }
        return attributes
    }
}
#endif
