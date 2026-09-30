import CoreGraphics

/// Row and native disclosure geometry carried by the tree's immutable style snapshot.
public struct CloudTreeRowGrid: Equatable, Sendable {
    public var disclosureSlot: CGFloat = 16
    public var disclosureGap: CGFloat = 2
    /// Width of the leading unread-indicator column on rows that can carry attention.
    public var attentionSlot: CGFloat = 12
    public var dotGap: CGFloat = 4
    public var detailGap: CGFloat = 5
    public var trailingGap: CGFloat = 10
    var trailingSlot: CGFloat = 16
    public var trailingPadding: CGFloat = 12
    public var machineLineSpacing: CGFloat = 1

    public init(
        disclosureSlot: CGFloat = 16,
        disclosureGap: CGFloat = 2,
        attentionSlot: CGFloat = 12,
        dotGap: CGFloat = 4,
        detailGap: CGFloat = 5,
        trailingGap: CGFloat = 10,
        trailingSlot: CGFloat = 16,
        trailingPadding: CGFloat = 12,
        machineLineSpacing: CGFloat = 1
    ) {
        self.disclosureSlot = disclosureSlot
        self.disclosureGap = disclosureGap
        self.attentionSlot = attentionSlot
        self.dotGap = dotGap
        self.detailGap = detailGap
        self.trailingGap = trailingGap
        self.trailingSlot = trailingSlot
        self.trailingPadding = trailingPadding
        self.machineLineSpacing = machineLineSpacing
    }
}
