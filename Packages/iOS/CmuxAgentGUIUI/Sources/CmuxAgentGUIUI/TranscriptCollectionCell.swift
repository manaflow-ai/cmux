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
