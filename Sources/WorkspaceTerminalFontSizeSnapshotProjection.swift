import CmuxTerminal
import CmuxTerminalCore
import Foundation

/// Read-only overlay used while serializing a workspace or Dock.
///
/// Native font rebuilds remain bounded across run-loop turns. A snapshot
/// instead replays the accepted request metadata over each terminal's current
/// lineage, so persistence observes the final intent without synchronously
/// draining renderer work.
@MainActor
struct WorkspaceTerminalFontSizeSnapshotProjection {
    private let commonIntents: [Intent]
    private let panelIntents: [UUID: [Intent]]

    init(
        commonIntents: [Intent],
        panelIntents: [UUID: [Intent]]
    ) {
        self.commonIntents =
            commonIntents.sorted(by: Intent.precedes)
        self.panelIntents = panelIntents.mapValues {
            $0.sorted(by: Intent.precedes)
        }
    }

    func sessionProjection(
        for terminalPanel: TerminalPanel
    ) -> SessionProjection {
        guard let projection = lineageProjection(
            for: terminalPanel
        ) else {
            return SessionProjection(
                overrideBasePoints:
                    terminalPanel.surface
                        .sessionFontSizeOverrideBasePoints(),
                representedRequestTokens: []
            )
        }
        guard let lineage = projection.lineage,
              lineage.isExplicitOverride,
              TerminalFontSizePolicy()
                .acceptsPersistedBasePoints(
                    lineage.basePoints
                ) else {
            return SessionProjection(
                overrideBasePoints: nil,
                representedRequestTokens:
                    projection.representedRequestTokens
            )
        }
        return SessionProjection(
            overrideBasePoints: lineage.basePoints,
            representedRequestTokens:
                projection.representedRequestTokens
        )
    }

    func lineageProjection(
        for terminalPanel: TerminalPanel
    ) -> LineageProjection? {
        var intentsByToken: [UUID: Intent] = [:]
        for intent in commonIntents {
            intentsByToken[intent.requestToken] = intent
        }
        for intent in panelIntents[terminalPanel.id] ?? [] {
            intentsByToken[intent.requestToken] = intent
        }
        let intents = intentsByToken.values.sorted(
            by: Intent.precedes
        )
        guard let firstIntent = intents.first else {
            return nil
        }

        var lineage =
            terminalPanel.surface.fontSizeLineageSnapshot(
                magnificationPercent:
                    firstIntent.magnificationPercent
            )
        var projectedTokens: Set<UUID> = []
        var representedRequestTokens: Set<UUID> = []
        for intent in intents {
            let alreadyIncludesChange =
                terminalPanel.surface.hasAppliedFontSizeChange(
                    token: intent.requestToken
                )
                || terminalPanel.surface.hasAppliedFontSizeChange(
                    token: intent.counterpartTransferToken
                )
                || projectedTokens.contains(intent.requestToken)
                || projectedTokens.contains(
                    intent.counterpartTransferToken
                )
            if !alreadyIncludesChange {
                lineage =
                    intent.change
                        .resultingInheritanceLineage(
                            from: lineage,
                            configuredRuntimePoints:
                                intent.configuredRuntimePoints,
                            magnificationPercent:
                                intent.magnificationPercent
                        )
                projectedTokens.insert(intent.requestToken)
                projectedTokens.insert(
                    intent.requestTransferToken
                )
            }
            representedRequestTokens.insert(
                intent.requestToken
            )
        }
        return LineageProjection(
            lineage: lineage,
            representedRequestTokens:
                representedRequestTokens
        )
    }
}
