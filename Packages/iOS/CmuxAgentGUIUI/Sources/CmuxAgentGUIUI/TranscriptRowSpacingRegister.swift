import Foundation

struct TranscriptRowSpacingRegister: Hashable, Sendable {
    let intraGroup: CGFloat
    let activity: CGFloat
    let interGroup: CGFloat
    let turnBottom: CGFloat
    let activityItem: CGFloat
    let metadataVerticalPadding: CGFloat
    let activityVerticalPadding: CGFloat
    let activityItemHeight: CGFloat
    let activitySummaryLabelHeight: CGFloat
    let activitySummaryMinimumHeight: CGFloat

    static func register(for density: TranscriptDensity) -> Self {
        switch density {
        case .comfortable:
            Self(
                intraGroup: 4,
                activity: 8,
                interGroup: 12,
                turnBottom: 16,
                activityItem: 1,
                metadataVerticalPadding: 4,
                activityVerticalPadding: 4,
                activityItemHeight: 24,
                activitySummaryLabelHeight: 26,
                activitySummaryMinimumHeight: 44
            )
        case .compact:
            Self(
                intraGroup: 2,
                activity: 5,
                interGroup: 8,
                turnBottom: 10,
                activityItem: 1,
                metadataVerticalPadding: 1,
                activityVerticalPadding: 1,
                activityItemHeight: 18,
                activitySummaryLabelHeight: 20,
                activitySummaryMinimumHeight: 32
            )
        }
    }
}
