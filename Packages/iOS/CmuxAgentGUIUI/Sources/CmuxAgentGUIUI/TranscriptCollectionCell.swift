#if os(iOS)
import CmuxAgentGUIProjection
import CmuxAgentReplica
import SwiftUI
import UIKit

final class TranscriptCollectionCell: UICollectionViewCell {
    private(set) var rowSpacing = TranscriptRowSpacing(top: 0, bottom: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private(set) var rowKind: TranscriptRowKind?
    private(set) var row: TranscriptRow?

    func configure(
        row: TranscriptRow,
        spacing: TranscriptRowSpacing,
        theme: AgentGUITheme,
        answeringAskID: String?,
        failedAskID: String?,
        onShowActivity: @escaping (TranscriptActivityDetails) -> Void,
        onAnswer: @escaping (PendingAsk, Int) -> Void,
        onShowTerminal: @escaping () -> Void
    ) {
        self.row = row
        rowKind = row.rowKind
        rowSpacing = spacing
        contentConfiguration = UIHostingConfiguration {
            TranscriptRowContentView(
                row: row,
                spacing: spacing,
                theme: theme,
                answeringAskID: answeringAskID,
                failedAskID: failedAskID,
                onShowActivity: onShowActivity,
                onAnswer: onAnswer,
                onShowTerminal: onShowTerminal
            )
        }
        .margins(.all, 0)
        // UICollectionViewCell may refresh its default background when its
        // hosting configuration changes. Reassert transparency so the single
        // transcript canvas remains visible through row gaps.
        backgroundConfiguration = .clear()
        contentView.backgroundColor = .clear
        if case .pendingAsk = row.rowKind {
            isAccessibilityElement = false
            accessibilityLabel = nil
        } else {
            isAccessibilityElement = true
            accessibilityTraits = .staticText
            accessibilityLabel = row.accessibilityLabel
        }
    }

}
#endif
