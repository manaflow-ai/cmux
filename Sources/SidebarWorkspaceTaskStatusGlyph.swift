import CmuxWorkspaces
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

/// Pure mapping from a task status (+ manual-override flag) to the drawn
/// glyph's shape: how much of the circle is filled, which color role it
/// takes, and whether the checkmark / override dot render. Kept free of
/// SwiftUI so the mapping is unit-testable.
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
    /// A manual (non-inferred) status renders a small dot at the lower right.
    let showsOverrideDot: Bool

    init(status: WorkspaceTaskStatus, hasOverride: Bool) {
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
        showsOverrideDot = hasOverride
    }

    /// The localized tooltip: lane name plus whether it was set manually or
    /// inferred from live signals.
    static func tooltip(status: WorkspaceTaskStatus, hasOverride: Bool) -> String {
        if hasOverride {
            return String(
                format: String(
                    localized: "sidebar.status.tooltip.manual",
                    defaultValue: "%@ — set manually"
                ),
                locale: .current,
                status.displayName
            )
        }
        return String(
            format: String(
                localized: "sidebar.status.tooltip.inferred",
                defaultValue: "%@ — inferred"
            ),
            locale: .current,
            status.displayName
        )
    }
}

// MARK: - Glyph view

/// The custom-drawn circular progress-pie status glyph rendered as the
/// leftmost element of a sidebar workspace row's title line. Drawn in a
/// fixed-width slot sized like the pin glyph (~9pt, font-scaled). Modeled on
/// `PullRequestOpenIcon`/`PullRequestMergedIcon` (custom `Path` drawing, row
/// passes resolved colors; no store access below the snapshot boundary).
struct SidebarWorkspaceTaskStatusGlyph: View {
    let status: WorkspaceTaskStatus
    let hasOverride: Bool
    /// Active (inverted-foreground) rows render monochrome, matching how
    /// `logLevelColor` flattens semantic colors on the selected row.
    let usesMonochrome: Bool
    /// The color used for every part of the glyph in monochrome mode.
    let monochromeColor: Color
    /// The secondary color used for the todo outline and the override dot.
    let neutralColor: Color
    let fontScale: CGFloat

    private static let baseSize: CGFloat = 9
    private static let slotWidth: CGFloat = 11
    private static let strokeWidth: CGFloat = 1
    private static let attentionStrokeWidth: CGFloat = 1.4
    private static let overrideDotSize: CGFloat = 2

    private var model: SidebarWorkspaceTaskStatusGlyphModel {
        SidebarWorkspaceTaskStatusGlyphModel(status: status, hasOverride: hasOverride)
    }

    private var statusColor: Color {
        if usesMonochrome { return monochromeColor }
        switch model.colorRole {
        case .neutral:
            return neutralColor
        case .working:
            return cmuxAccentColor()
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
            if model.showsCheckmark {
                SidebarStatusCheckmarkShape()
                    .stroke(
                        checkmarkColor,
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if model.showsOverrideDot {
                Circle()
                    .fill(neutralColor)
                    .frame(width: Self.overrideDotSize, height: Self.overrideDotSize)
                    .offset(x: 1, y: 1)
            }
        }
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

/// A small checkmark centered in the glyph's circle.
struct SidebarStatusCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        path.move(to: CGPoint(x: rect.minX + width * 0.28, y: rect.minY + height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.45, y: rect.minY + height * 0.68))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.74, y: rect.minY + height * 0.34))
        return path
    }
}
