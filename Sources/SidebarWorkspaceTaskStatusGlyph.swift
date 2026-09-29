import CmuxFoundation
import CmuxWorkspaces
import Foundation
import SwiftUI

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
/// the circle is filled, which color role it takes, and which mark renders
/// on top. Kept free of SwiftUI so the mapping is unit-testable.
/// Manual-override state surfaces only in the tooltip and the status
/// popover, never as extra glyph decoration.
///
/// Working and Needs Attention share a half-filled pie and differ only in
/// color. With the macOS Differentiate Without Color setting on, Needs
/// Attention instead draws a filled circle with an exclamation mark, so
/// every lane has a distinct shape.
struct SidebarWorkspaceTaskStatusGlyphModel: Equatable {
    /// The mark drawn over the circle, in the contrasting mark color.
    enum Mark: Equatable {
        case none
        /// Done.
        case checkmark
        /// Needs attention, only with Differentiate Without Color on.
        case exclamation
    }

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
    let mark: Mark

    /// Done renders a checkmark over the filled circle.
    var showsCheckmark: Bool { mark == .checkmark }

    init(status: WorkspaceTaskStatus, differentiateWithoutColor: Bool = false) {
        switch status {
        case .todo:
            fillFraction = 0
            colorRole = .neutral
            mark = .none
        case .working:
            fillFraction = 0.5
            colorRole = .working
            mark = .none
        case .needsAttention:
            fillFraction = differentiateWithoutColor ? 1 : 0.5
            colorRole = .attention
            mark = differentiateWithoutColor ? .exclamation : .none
        case .review:
            fillFraction = 0.75
            colorRole = .review
            mark = .none
        case .done:
            fillFraction = 1
            colorRole = .done
            mark = .checkmark
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

// MARK: - Row status menu

/// The interactive wrapper used only by sidebar workspace rows with a
/// manual status override. It keeps the restored row glyph compact while
/// sending every selection through the shared workspace todo action path.
struct SidebarWorkspaceManualStatusIndicatorMenu: View {
    let status: WorkspaceTaskStatus
    let model: SidebarWorkspaceCompactStatusMenuModel
    let workspaceId: UUID
    let applyTodoStatus: (WorkspaceTaskStatus?, [UUID]) -> Void
    let hideTodoStatus: ([UUID]) -> Void
    let usesMonochrome: Bool
    let monochromeColor: Color
    let neutralColor: Color
    let fontScale: CGFloat

    @State private var isStatusPopoverPresented = false

    private var labelText: String {
        String(localized: "sidebar.status.compactLabel", defaultValue: "Status: \(status.displayName)")
    }

    var body: some View {
        Button {
            isStatusPopoverPresented.toggle()
        } label: {
            SidebarWorkspaceTaskStatusGlyph(
                status: status,
                hasOverride: true,
                usesMonochrome: usesMonochrome,
                monochromeColor: monochromeColor,
                neutralColor: neutralColor,
                fontScale: fontScale
            )
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .backport.pointerStyle(.link)
        .background(
            SidebarWorkspaceTodoPopoverHost(
                isPresented: $isStatusPopoverPresented,
                model: SidebarWorkspaceStatusPopoverModel(
                    inferred: model.inferred,
                    activeOverride: model.activeOverride
                ),
                minWidth: 200,
                maxHeight: 400,
                preferredEdge: .maxY
            ) { model, close in
                SidebarWorkspaceStatusPopover(
                    model: model,
                    onSelectLane: { status in
                        applyTodoStatus(status, [workspaceId])
                    },
                    onSelectNone: {
                        hideTodoStatus([workspaceId])
                    },
                    onClose: close
                )
            }
        )
        .fixedSize(horizontal: true, vertical: true)
        .safeHelp(String(localized: "sidebar.status.compactTooltip", defaultValue: "Change workspace status"))
        .accessibilityLabel(labelText)
        .accessibilityIdentifier("SidebarWorkspaceManualStatusIndicatorMenu")
    }
}

// MARK: - Glyph view

/// The custom-drawn circular progress-pie status glyph shown in the todo
/// pane's header, the status popover's lane rows, and the sidebar row only
/// when a manual workspace status is set. Automatic status never draws a row
/// glyph. Drawn in a fixed-width slot
/// (~9pt base, font-scaled). Modeled on `PullRequestOpenIcon`/
/// `PullRequestMergedIcon` (custom `Path` drawing, caller passes resolved
/// colors; no store access).
struct SidebarWorkspaceTaskStatusGlyph: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    let status: WorkspaceTaskStatus
    let hasOverride: Bool
    /// Active (inverted-foreground) rows render monochrome, matching how
    /// `logLevelColor` flattens semantic colors on the selected row.
    let usesMonochrome: Bool
    /// The color used for every part of the glyph in monochrome mode.
    let monochromeColor: Color
    /// The secondary color used for the todo outline.
    let neutralColor: Color
    let fontScale: CGFloat

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private static let baseSize: CGFloat = 9
    private static let slotWidth: CGFloat = 11
    private static let strokeWidth: CGFloat = 1
    private static let attentionStrokeWidth: CGFloat = 1.4

    private var model: SidebarWorkspaceTaskStatusGlyphModel {
        SidebarWorkspaceTaskStatusGlyphModel(
            status: status,
            differentiateWithoutColor: differentiateWithoutColor
        )
    }

    private var statusColor: Color {
        if usesMonochrome { return monochromeColor }
        switch model.colorRole {
        case .neutral:
            return neutralColor
        case .working:
            return cmuxAccent.color
        case .attention:
            // Loudest lane: full-strength attention accent between orange and red.
            return Color(red: 1.0, green: 0.42, blue: 0.2)
        case .review:
            return .green
        case .done:
            // Muted gray-green so finished rows read as settled, not celebratory.
            return Color(red: 0.45, green: 0.62, blue: 0.5)
        }
    }

    private var strokeWidth: CGFloat {
        model.colorRole == .attention ? Self.attentionStrokeWidth : Self.strokeWidth
    }

    var body: some View {
        let size = Self.baseSize * fontScale
        let tooltip = SidebarWorkspaceTaskStatusGlyphModel.tooltip(status: status, hasOverride: hasOverride)
        ZStack {
            Circle()
                .stroke(statusColor, lineWidth: strokeWidth)
            if model.fillFraction >= 1 {
                Circle()
                    .fill(statusColor)
            } else if model.fillFraction > 0 {
                SidebarStatusPieShape(fraction: model.fillFraction)
                    .fill(statusColor)
            }
            SidebarStatusMarkShape(mark: model.mark)
                .stroke(
                    checkmarkColor,
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(width: size, height: size)
        // Fixed-width slot so titles align whether or not the pie is drawn
        // wider by the attention stroke.
        .frame(width: Self.slotWidth * fontScale, alignment: .center)
        .safeHelp(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var checkmarkColor: Color {
        usesMonochrome ? Color.black.opacity(0.7) : Color.white
    }
}

/// A pie slice from 12 o'clock sweeping clockwise by `fraction` of the circle.
struct SidebarStatusPieShape: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * max(0, min(fraction, 1))),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// The glyph's mark (checkmark or exclamation) centered in its circle;
/// empty when the lane has no mark.
struct SidebarStatusMarkShape: Shape {
    let mark: SidebarWorkspaceTaskStatusGlyphModel.Mark

    func path(in rect: CGRect) -> Path {
        mark.path(in: rect).map { Path($0) } ?? Path()
    }
}

extension SidebarWorkspaceTaskStatusGlyphModel.Mark {
    /// The mark's stroke path inside the glyph's circle rect, or `nil` for
    /// no mark. Shared by the SwiftUI glyph and the AppKit row button (both
    /// stroke it 1.2pt, round). Coordinates are y-down, matching SwiftUI and
    /// the flipped AppKit view.
    func path(in rect: CGRect) -> CGPath? {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        let path = CGMutablePath()
        switch self {
        case .none:
            return nil
        case .checkmark:
            path.move(to: point(0.28, 0.52))
            path.addLine(to: point(0.45, 0.68))
            path.addLine(to: point(0.74, 0.34))
        case .exclamation:
            path.move(to: point(0.5, 0.24))
            path.addLine(to: point(0.5, 0.54))
            // A near-zero segment: the round cap draws the dot.
            path.move(to: point(0.5, 0.75))
            path.addLine(to: point(0.5, 0.76))
        }
        return path
    }
}

