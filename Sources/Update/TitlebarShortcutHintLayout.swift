import AppKit
import Bonsplit
import Combine
import SwiftUI


// MARK: - Shortcut hint lane & pill layout planning
struct ShortcutHintLanePlanner {
    static func assignLanes(for intervals: [ClosedRange<CGFloat>], minSpacing: CGFloat = 4) -> [Int] {
        guard !intervals.isEmpty else { return [] }

        var laneMaxX: [CGFloat] = []
        var lanes: [Int] = []
        lanes.reserveCapacity(intervals.count)

        for interval in intervals {
            var lane = 0
            while lane < laneMaxX.count {
                let requiredMinX = laneMaxX[lane] + minSpacing
                if interval.lowerBound >= requiredMinX {
                    break
                }
                lane += 1
            }

            if lane == laneMaxX.count {
                laneMaxX.append(interval.upperBound)
            } else {
                laneMaxX[lane] = max(laneMaxX[lane], interval.upperBound)
            }
            lanes.append(lane)
        }

        return lanes
    }
}

struct ShortcutHintHorizontalPlanner {
    static func assignRightEdges(
        for intervals: [ClosedRange<CGFloat>],
        minSpacing: CGFloat = 6,
        minLeadingEdge: CGFloat = 0
    ) -> [CGFloat] {
        guard !intervals.isEmpty else { return [] }

        var assignedRightEdges = Array(repeating: CGFloat.zero, count: intervals.count)
        var nextMaxRight = CGFloat.greatestFiniteMagnitude

        for index in stride(from: intervals.count - 1, through: 0, by: -1) {
            let interval = intervals[index]
            let width = interval.upperBound - interval.lowerBound
            let preferredRightEdge = interval.upperBound
            let adjustedRightEdge = min(preferredRightEdge, nextMaxRight)
            assignedRightEdges[index] = adjustedRightEdge
            nextMaxRight = adjustedRightEdge - width - minSpacing
        }

        let assignedLeftEdges = zip(intervals, assignedRightEdges).map { interval, rightEdge in
            rightEdge - (interval.upperBound - interval.lowerBound)
        }
        if let minAssignedLeftEdge = assignedLeftEdges.min(), minAssignedLeftEdge < minLeadingEdge {
            let shift = minLeadingEdge - minAssignedLeftEdge
            assignedRightEdges = assignedRightEdges.map { $0 + shift }
        }

        return assignedRightEdges
    }
}

func titlebarShortcutHintHeight(for config: TitlebarControlsStyleConfig) -> CGFloat {
    max(14, config.iconSize + 1)
}

/// Width of a titlebar shortcut-hint pill, measured with the same font `ShortcutHintPill`
/// renders with (SF Rounded at the pill's font size). Measuring with the default
/// (non-rounded) system font underestimated command-symbol glyphs and let the pill
/// overflow its reserved slot. The `+ 12` matches the pill's 6pt horizontal padding per side.
func titlebarHintPillWidth(for shortcut: StoredShortcut, config: TitlebarControlsStyleConfig) -> CGFloat {
    let pillFontSize = max(8, config.iconSize - 5)
    let baseFont = NSFont.systemFont(ofSize: pillFontSize, weight: .semibold)
    let pillFont = baseFont.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: pillFontSize) } ?? baseFont
    let textWidth = (shortcut.displayString as NSString).size(withAttributes: [.font: pillFont]).width
    return ceil(textWidth) + 12
}

/// The rightmost edge the shortcut-hint pills occupy, in the controls' content
/// coordinate space (measured from the leading edge of the button row), after the
/// horizontal planner resolves overlaps.
///
/// This mirrors `TitlebarControlsView.titlebarHintIntervals` and the
/// `ShortcutHintHorizontalPlanner` so the accessory reserves exactly enough width for
/// the real layout. It is computed unconditionally for every command-bound slot (not
/// gated on modifier state) so the reserved width stays stable whether or not the hints
/// are currently visible. Returns 0 when no slot would show a hint.
func titlebarHintLayoutRightmostExtent(
    config: TitlebarControlsStyleConfig,
    titlebarShortcutHintXOffset: Double = ShortcutHintDebugSettings.defaultTitlebarHintX
) -> CGFloat {
    let xOffset = CGFloat(ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset))
    var intervals: [ClosedRange<CGFloat>] = []
    for slot in TitlebarShortcutHintActionSlot.allCases {
        let shortcut = KeyboardShortcutSettings.shortcut(for: slot.action)
        guard !shortcut.isUnbound, shortcut.command else { continue }
        let width = titlebarHintPillWidth(for: shortcut, config: config)
        intervals.append(
            TitlebarControlsLayoutMetrics.hintInterval(
                for: slot,
                width: width,
                config: config,
                xOffset: xOffset
            )
        )
    }
    guard !intervals.isEmpty else { return 0 }
    return intervals.map(\.upperBound).max() ?? 0
}

enum TitlebarShortcutHintMetrics {
    static let verticalGap: CGFloat = -3
}

func titlebarShortcutHintVerticalOffset(for config: TitlebarControlsStyleConfig) -> CGFloat {
    config.buttonSize + TitlebarShortcutHintMetrics.verticalGap
}

enum TitlebarShortcutHintActionSlot: Int, CaseIterable {
    case toggleSidebar
    case showNotifications
    case newTab
    case focusHistoryBack
    case focusHistoryForward

    var action: KeyboardShortcutSettings.Action {
        switch self {
        case .toggleSidebar:
            return .toggleSidebar
        case .showNotifications:
            return .showNotifications
        case .newTab:
            return .newTab
        case .focusHistoryBack:
            return .focusHistoryBack
        case .focusHistoryForward:
            return .focusHistoryForward
        }
    }

}

