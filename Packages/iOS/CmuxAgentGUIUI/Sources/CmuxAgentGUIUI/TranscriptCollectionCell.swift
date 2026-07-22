#if os(iOS)
import CmuxAgentGUIProjection
import CmuxAgentReplica
import UIKit

final class TranscriptCollectionCell: UICollectionViewCell {
    private(set) var rowSpacing = TranscriptRowSpacing(top: 0, bottom: 0)
    private let rowView = TranscriptRowView()
    private(set) var rowLayoutResult: TranscriptRowLayoutResult?

    var contentBoundsIncludingSubviews: CGRect {
        rowView.contentBoundsIncludingSubviews
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        contentView.addSubview(rowView)
        clipsToBounds = true
        contentView.clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    private(set) var rowKind: TranscriptRowKind?
    private(set) var row: TranscriptRow?

    func configure(
        row: TranscriptRow,
        spacing: TranscriptRowSpacing,
        layout: TranscriptRowLayoutResult,
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
        rowLayoutResult = layout
        rowView.configure(
            row: row,
            layout: layout,
            theme: theme,
            answeringAskID: answeringAskID,
            onShowActivity: onShowActivity,
            onAnswer: onAnswer,
            onShowTerminal: onShowTerminal
        )
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
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let layout = TranscriptRowLayout.layout(
            row: row,
            width: max(bounds.width, 1),
            spacing: spacing,
            scale: scale,
            askState: TranscriptAskLayoutState(
                isAnswering: answeringAskID == row.pendingAskID,
                hasFailed: failedAskID == row.pendingAskID
            ),
            traitCollection: traitCollection
        )
        configure(
            row: row,
            spacing: spacing,
            layout: layout,
            theme: theme,
            answeringAskID: answeringAskID,
            failedAskID: failedAskID,
            onShowActivity: onShowActivity,
            onAnswer: onAnswer,
            onShowTerminal: onShowTerminal
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rowView.frame = contentView.bounds
    }

}

private extension TranscriptRow {
    var pendingAskID: String? {
        guard case .pendingAsk(let ask) = rowKind else { return nil }
        return ask.id
    }
}
#endif
