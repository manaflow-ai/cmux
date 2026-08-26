import CmuxFoundation
import CmuxTerminal
import CmuxTerminalCore
import Foundation

/// Predicts descendant font lineage while a bounded workspace request drains.
@MainActor
struct TerminalFontSizeChangeInheritanceContext {
    let token: UUID
    let change: WorkspaceTerminalFontSizeChange
    let configuredRuntimePoints: Float32
    let magnificationPercent: Int
    let fallbackLineage: TerminalFontSizeLineage
    let initialLineageProbeCount: Int

    init(
        token: UUID,
        change: WorkspaceTerminalFontSizeChange,
        configuredRuntimePoints: Float32,
        magnificationPercent: Int =
            GlobalFontMagnification.storedPercent,
        preferredSourcePanel: TerminalPanel?,
        fallbackLineage: TerminalFontSizeLineage?,
        fallbackLineageAlreadyIncludesChange: Bool = false
    ) {
        self.token = token
        self.change = change
        self.configuredRuntimePoints = configuredRuntimePoints
        self.magnificationPercent =
            GlobalFontMagnification.clamp(magnificationPercent)

        let preferredSourceLineage =
            preferredSourcePanel?.surface.fontSizeLineageForAdjustment(
                fallbackRuntimePoints: configuredRuntimePoints,
                magnificationPercent: self.magnificationPercent
            )
        initialLineageProbeCount = preferredSourcePanel == nil ? 0 : 1
        if preferredSourceLineage == nil,
           fallbackLineageAlreadyIncludesChange,
           let fallbackLineage {
            self.fallbackLineage = fallbackLineage
        } else {
            self.fallbackLineage = change.resultingInheritanceLineage(
                from: preferredSourceLineage ?? fallbackLineage,
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: self.magnificationPercent
            )
        }
    }

    func inheritedLineage(
        from sourceTerminalPanel: TerminalPanel?
    ) -> TerminalFontSizeLineage {
        guard let sourceTerminalPanel else { return fallbackLineage }
        let sourceLineage =
            sourceTerminalPanel.surface.fontSizeLineageForAdjustment(
                fallbackRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
        return inheritedLineage(
            from: sourceLineage,
            alreadyIncludesChange:
                sourceTerminalPanel.surface
                    .hasAppliedFontSizeChange(
                        token: token
                    )
        )
    }

    func inheritedLineage(
        from sourceLineage: TerminalFontSizeLineage?,
        alreadyIncludesChange: Bool
    ) -> TerminalFontSizeLineage {
        if alreadyIncludesChange {
            return sourceLineage ?? fallbackLineage
        }
        if let sourceLineage {
            return change.resultingInheritanceLineage(
                from: sourceLineage,
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
        }
        return fallbackLineage
    }
}
