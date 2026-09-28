#if DEBUG
import SwiftUI

/// Persisted geometry edited by the spacing lab and resolved into one render snapshot.
public struct CloudSidebarDebugMetrics: Codable, Equatable, Sendable {
    public var referenceInset: Double = 12
    public var disclosureSlot: Double = 16
    public var disclosureGap: Double = 2
    /// Retained for saved tuning data; machine glyphs now use the shared iconSlot.
    var dotSlot: Double = 11
    public var dotGap: Double = 4
    public var detailGap: Double = 5
    public var trailingGap: Double = 10
    public var machineLineSpacing: Double = 1
    public var rowHeight: Double = 22
    public var indentPerLevel: Double = 10
    public var iconSlot: Double = 16
    public var iconGap: Double = 4
    public var machineVerticalPadding: Double = 2

    public static let `default` = Self()

    public func copyPayload(styleID: String) -> String {
        let metrics = self
        return """
        cloudTreeStyle=\(styleID)
        referenceInset=\(metrics.referenceInset)
        disclosureSlot=\(metrics.disclosureSlot)
        disclosureGap=\(metrics.disclosureGap)
        dotGap=\(metrics.dotGap)
        detailGap=\(metrics.detailGap)
        trailingGap=\(metrics.trailingGap)
        machineLineSpacing=\(metrics.machineLineSpacing)
        rowHeight=\(metrics.rowHeight)
        indentPerLevel=\(metrics.indentPerLevel)
        iconSlot=\(metrics.iconSlot)
        iconGap=\(metrics.iconGap)
        machineVerticalPadding=\(metrics.machineVerticalPadding)
        """
    }

    public func resolvedStyle(_ base: CloudTreeStyle) -> CloudTreeStyle {
        let metrics = self
        return CloudTreeStyle(
            id: base.id + ".debug." + [
                metrics.referenceInset,
                metrics.disclosureSlot,
                metrics.disclosureGap,
                metrics.dotGap,
                metrics.detailGap,
                metrics.trailingGap,
                metrics.machineLineSpacing,
                metrics.rowHeight,
                metrics.indentPerLevel,
                metrics.iconSlot,
                metrics.iconGap,
                metrics.machineVerticalPadding
            ].map { String($0) }.joined(separator: "-"),
            name: base.name,
            rowHeight: CGFloat(metrics.rowHeight),
            machineRowLayout: base.machineRowLayout,
            leafLayout: base.leafLayout,
            iconTreatment: base.iconTreatment,
            groupLabelStyle: base.groupLabelStyle,
            metaPlacement: base.metaPlacement,
            machineBand: base.machineBand,
            monospacedText: base.monospacedText,
            rowSeparators: base.rowSeparators,
            indentPerLevel: CGFloat(metrics.indentPerLevel),
            machineNameSize: base.machineNameSize,
            titleSize: base.titleSize,
            detailSize: base.detailSize,
            groupLabelSize: base.groupLabelSize,
            iconSize: base.iconSize,
            iconSlot: CGFloat(metrics.iconSlot),
            iconGap: CGFloat(metrics.iconGap),
            showsGroupCounts: base.showsGroupCounts,
            showsViewBadges: base.showsViewBadges,
            showsMachineStats: base.showsMachineStats,
            machineVerticalPadding: CGFloat(metrics.machineVerticalPadding),
            rowGrid: CloudTreeRowGrid(
                disclosureSlot: CGFloat(metrics.disclosureSlot),
                disclosureGap: CGFloat(metrics.disclosureGap),
                dotGap: CGFloat(metrics.dotGap),
                detailGap: CGFloat(metrics.detailGap),
                trailingGap: CGFloat(metrics.trailingGap),
                trailingPadding: CGFloat(metrics.referenceInset),
                machineLineSpacing: CGFloat(metrics.machineLineSpacing)
            )
        )
    }

    public init(
        referenceInset: Double = 12,
        disclosureSlot: Double = 16,
        disclosureGap: Double = 2,
        dotSlot: Double = 11,
        dotGap: Double = 4,
        detailGap: Double = 5,
        trailingGap: Double = 10,
        machineLineSpacing: Double = 1,
        rowHeight: Double = 22,
        indentPerLevel: Double = 10,
        iconSlot: Double = 16,
        iconGap: Double = 4,
        machineVerticalPadding: Double = 2
    ) {
        self.referenceInset = referenceInset
        self.disclosureSlot = disclosureSlot
        self.disclosureGap = disclosureGap
        self.dotSlot = dotSlot
        self.dotGap = dotGap
        self.detailGap = detailGap
        self.trailingGap = trailingGap
        self.machineLineSpacing = machineLineSpacing
        self.rowHeight = rowHeight
        self.indentPerLevel = indentPerLevel
        self.iconSlot = iconSlot
        self.iconGap = iconGap
        self.machineVerticalPadding = machineVerticalPadding
    }
}
#endif
