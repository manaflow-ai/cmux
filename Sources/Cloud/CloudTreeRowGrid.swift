import CoreGraphics

/// Row and native disclosure geometry carried by the tree's immutable style snapshot.
struct CloudTreeRowGrid: Equatable, Sendable {
    var disclosureSlot: CGFloat = 16
    var disclosureGap: CGFloat = 4
    var dotGap: CGFloat = 4
    var detailGap: CGFloat = 5
    var trailingGap: CGFloat = 10
    var trailingSlot: CGFloat = 16
    var trailingPadding: CGFloat = 12
    var machineLineSpacing: CGFloat = 1
}
