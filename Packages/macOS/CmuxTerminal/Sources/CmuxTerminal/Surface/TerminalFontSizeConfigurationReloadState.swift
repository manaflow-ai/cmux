import CmuxTerminalCore
import Foundation

/// Durable font ownership captured before Ghostty replaces app configuration.
///
/// Callers keep this value opaque and return it to the same surface after the
/// native config update. This prevents post-reload runtime points from being
/// mistaken for an externally adjusted durable base.
public struct TerminalFontSizeConfigurationReloadState: Sendable {
    let transactionId: UUID
    let surfaceId: UUID
    let lineage: TerminalFontSizeLineage?
    var inheritanceLineage:
        TerminalFontSizeLineage?
    let followsConfiguredFontSize: Bool
    let targetConfiguredRuntimePoints: Float32?
    let targetMagnificationPercent: Int?
    var localRuntimePointDelta: Float32 = 0
    var localAbsoluteRuntimePoints: Float32?
    var localInputUsesConfiguredBase = false
    var localInputIsExplicitOverride: Bool?

    mutating func recordRelativeFontInput(
        previousRuntimePoints: Float32,
        currentRuntimePoints: Float32,
        previousIsAdjusted: Bool,
        currentIsAdjusted: Bool
    ) {
        let runtimePointDelta =
            currentRuntimePoints
            - previousRuntimePoints
        if !previousIsAdjusted {
            localAbsoluteRuntimePoints = nil
            localInputUsesConfiguredBase = true
            localRuntimePointDelta = 0
        }
        if let currentAbsoluteRuntimePoints =
                localAbsoluteRuntimePoints {
            localAbsoluteRuntimePoints =
                currentAbsoluteRuntimePoints
                + runtimePointDelta
        } else {
            localRuntimePointDelta += runtimePointDelta
        }
        localInputIsExplicitOverride =
            currentIsAdjusted
        inheritanceLineage = resolvedTargetLineage()
    }

    mutating func recordResetFontInput() {
        localAbsoluteRuntimePoints = nil
        localInputUsesConfiguredBase = true
        localRuntimePointDelta = 0
        localInputIsExplicitOverride = false
        inheritanceLineage = resolvedTargetLineage()
    }

    mutating func recordAbsoluteFontInput(
        currentRuntimePoints: Float32,
        currentIsAdjusted: Bool
    ) {
        localAbsoluteRuntimePoints =
            currentRuntimePoints
        localInputUsesConfiguredBase = false
        localRuntimePointDelta = 0
        localInputIsExplicitOverride =
            currentIsAdjusted
        inheritanceLineage = resolvedTargetLineage()
    }

    func resolvedTargetLineage()
        -> TerminalFontSizeLineage? {
        guard let targetConfiguredRuntimePoints,
              targetConfiguredRuntimePoints.isFinite,
              targetConfiguredRuntimePoints > 0,
              let targetMagnificationPercent else {
            return inheritanceLineage
        }
        return resolvedTarget(
            configuredRuntimePoints:
                targetConfiguredRuntimePoints,
            magnificationPercent:
                targetMagnificationPercent
        ).lineage
    }

    func resolvedTarget(
        configuredRuntimePoints: Float32,
        magnificationPercent: Int
    ) -> TerminalFontSizeConfigurationReloadResolvedTarget {
        let policy = TerminalFontSizePolicy()
        let configuredRuntimePoints = policy.clampedRuntimePoints(
            configuredRuntimePoints
        )
        let originallyRetainsExplicitBase =
            lineage?.isExplicitOverride
            ?? !followsConfiguredFontSize
        let startsFromConfiguredBase =
            localInputUsesConfiguredBase
            || !originallyRetainsExplicitBase
        let baselineRuntimePoints: Float32
        if let localAbsoluteRuntimePoints {
            baselineRuntimePoints =
                localAbsoluteRuntimePoints
        } else if startsFromConfiguredBase {
            baselineRuntimePoints = configuredRuntimePoints
        } else if let lineage {
            baselineRuntimePoints = policy.clampedRuntimePoints(
                CmuxSurfaceConfigTemplate.runtimeFontSize(
                    fromBasePoints: lineage.basePoints,
                    percent: magnificationPercent
                )
            )
        } else {
            baselineRuntimePoints = configuredRuntimePoints
        }
        let runtimePoints = policy.clampedRuntimePoints(
            baselineRuntimePoints + localRuntimePointDelta
        )
        let isExplicitOverride =
            localInputIsExplicitOverride
            ?? (
                localAbsoluteRuntimePoints != nil
                ||
                !startsFromConfiguredBase
                || abs(localRuntimePointDelta) > 0.000_1
            )
        let targetLineage: TerminalFontSizeLineage
        if isExplicitOverride,
           localAbsoluteRuntimePoints == nil,
           !localInputUsesConfiguredBase,
           abs(localRuntimePointDelta) <= 0.000_1,
           let lineage {
            targetLineage = TerminalFontSizeLineage(
                basePoints: lineage.basePoints,
                isExplicitOverride: true
            )
        } else {
            targetLineage = TerminalFontSizeLineage(
                basePoints:
                    CmuxSurfaceConfigTemplate.baseFontSize(
                        fromRuntimePoints: runtimePoints,
                        percent: magnificationPercent
                    ),
                isExplicitOverride: isExplicitOverride
            )
        }
        return TerminalFontSizeConfigurationReloadResolvedTarget(
            lineage: targetLineage,
            durableRuntimePoints: runtimePoints,
            retainsExplicitBase: isExplicitOverride
        )
    }
}
