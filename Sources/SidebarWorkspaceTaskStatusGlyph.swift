import CmuxWorkspaces
import Foundation

// MARK: - Status display names

extension WorkspaceTaskStatus {
    /// The localized lane name shown in menus, palette entries, and tooltips.
    var displayName: String {
        switch self {
        case .todo:
            return String(localized: "sidebar.status.todo", defaultValue: "Todo")
        case .working:
            return String(localized: "sidebar.status.working", defaultValue: "Working")
        case .needsAttention:
            return String(localized: "sidebar.status.needsAttention", defaultValue: "Needs Attention")
        case .review:
            return String(localized: "sidebar.status.review", defaultValue: "In Review")
        case .done:
            return String(localized: "sidebar.status.done", defaultValue: "Done")
        }
    }
}

// MARK: - Glyph model

/// Pure mapping from a task status to the drawn glyph's shape: how much of
/// the circle is filled, which color role it takes, and whether the
/// checkmark renders. Kept UI-framework-neutral so the mapping is unit-testable.
/// Manual-override state surfaces only in the tooltip and the status
/// popover, never as extra glyph decoration.
struct SidebarWorkspaceTaskStatusGlyphModel: Equatable {
    /// Semantic color the view resolves against the row's palette.
    enum ColorRole: Equatable {
        /// Todo: secondary gray outline only.
        case neutral
        /// Working: accent blue.
        case working
        /// Needs attention: the loudest role (orange/red attention accent).
        case attention
        /// In review: green.
        case review
        /// Done: muted gray-green.
        case done
    }

    /// Fraction of the progress pie that is filled, 0...1.
    let fillFraction: Double
    let colorRole: ColorRole
    /// Done renders a checkmark over the filled circle.
    let showsCheckmark: Bool

    init(status: WorkspaceTaskStatus) {
        switch status {
        case .todo:
            fillFraction = 0
            colorRole = .neutral
            showsCheckmark = false
        case .working:
            fillFraction = 0.5
            colorRole = .working
            showsCheckmark = false
        case .needsAttention:
            fillFraction = 0.5
            colorRole = .attention
            showsCheckmark = false
        case .review:
            fillFraction = 0.75
            colorRole = .review
            showsCheckmark = false
        case .done:
            fillFraction = 1
            colorRole = .done
            showsCheckmark = true
        }
    }

    /// Localized format strings resolved once, not per render.
    private static let manualTooltipFormat = String(
        localized: "sidebar.status.tooltip.manual",
        defaultValue: "%@ — set manually"
    )
    private static let inferredTooltipFormat = String(
        localized: "sidebar.status.tooltip.inferred",
        defaultValue: "%@ — inferred"
    )

    /// The localized tooltip: lane name plus whether it was set manually or
    /// inferred from live signals.
    static func tooltip(status: WorkspaceTaskStatus, hasOverride: Bool) -> String {
        String(
            format: hasOverride ? manualTooltipFormat : inferredTooltipFormat,
            locale: .current,
            status.displayName
        )
    }
}

/// Policy for the sidebar row's restored status indicator. Rows only show a
/// glyph for a human-set status while the remote todo-controls flag is on;
/// inferred/automatic status stays out of the row chrome.
struct SidebarWorkspaceManualTaskStatusIndicatorModel: Equatable {
    let featureEnabled: Bool
    let taskStatus: WorkspaceTaskStatus?
    let hasManualOverride: Bool

    var showsIndicator: Bool {
        featureEnabled && hasManualOverride && taskStatus != nil
    }
}
