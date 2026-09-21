import CoreGraphics

/// Row and native disclosure geometry carried by the tree's immutable style snapshot.
struct CloudTreeRowGrid: Equatable, Sendable {
    var disclosureSlot: CGFloat = 13
    var disclosureGap: CGFloat = 2
    var dotGap: CGFloat = 4
    var detailGap: CGFloat = 4
    var trailingGap: CGFloat = 0
    var trailingSlot: CGFloat = 16
    var trailingPadding: CGFloat = 8
    var machineLineSpacing: CGFloat = 1
}
