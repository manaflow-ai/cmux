import CoreGraphics
import Foundation

/// How one sidebar column presents its rows.
///
/// `regular` is the full row presentation. `icons` is the Finder-style
/// minimized rail the user reaches by dragging the column's divider below
/// its minimum regular width; rows render only their icon and details move
/// into a hover card.
enum SidebarColumnDisplayMode: String, Codable, Sendable {
    case regular
    case icons
}

/// Geometry contract for one resizable, icon-collapsible sidebar column.
///
/// The regular width band is `minimumRegularWidth...maximumRegularWidth`.
/// Dragging below `iconEnterThreshold` snaps the column to `railWidth` in
/// `icons` mode; dragging back past `iconExitThreshold` restores `regular`.
/// Enter and exit thresholds differ (hysteresis) so the pointer resting near
/// the boundary cannot flap the column between modes.
struct SidebarColumnWidthProfile: Equatable, Sendable {
    let railWidth: CGFloat
    let minimumRegularWidth: CGFloat
    let maximumRegularWidth: CGFloat
    let defaultRegularWidth: CGFloat

    /// Dragging a regular column below this snaps it to the icon rail.
    var iconEnterThreshold: CGFloat {
        minimumRegularWidth - Self.snapSlack
    }

    /// Dragging an icon rail past this restores the regular presentation.
    var iconExitThreshold: CGFloat {
        minimumRegularWidth
    }

    /// How far past the minimum the pointer must travel before the column
    /// commits to the icon rail. Keeps an ordinary "make it as narrow as
    /// possible" drag in regular mode.
    private static let snapSlack: CGFloat = 28

    static let machines = Self(
        railWidth: CGFloat(SessionPersistencePolicy.sidebarColumnIconRailWidth),
        minimumRegularWidth: CGFloat(SessionPersistencePolicy.minimumSidebarLeadingColumnWidth),
        maximumRegularWidth: CGFloat(SessionPersistencePolicy.maximumSidebarLeadingColumnWidth),
        defaultRegularWidth: CGFloat(SessionPersistencePolicy.defaultSidebarLeadingColumnWidth)
    )

    /// The workspaces column keeps its user-configurable minimum width.
    static func workspaces(
        minimumRegularWidth: CGFloat,
        maximumRegularWidth: CGFloat = CGFloat(SessionPersistencePolicy.maximumSidebarWidth)
    ) -> Self {
        Self(
            railWidth: CGFloat(SessionPersistencePolicy.sidebarColumnIconRailWidth),
            minimumRegularWidth: minimumRegularWidth,
            maximumRegularWidth: max(minimumRegularWidth, maximumRegularWidth),
            defaultRegularWidth: minimumRegularWidth
        )
    }

    func clampedRegularWidth(_ candidate: CGFloat) -> CGFloat {
        guard candidate.isFinite else { return defaultRegularWidth }
        return min(max(candidate, minimumRegularWidth), maximumRegularWidth)
    }
}

/// Pure resolution of live divider geometry to a column presentation.
/// Owns no state so both columns and the tests share one rule set.
enum SidebarColumnDisplayPolicy {
    struct Resolution: Equatable {
        let mode: SidebarColumnDisplayMode
        /// Effective width the column should occupy right now.
        let width: CGFloat
        /// Regular width to remember for restoring out of icon mode.
        /// `nil` when the drag carries no new regular width (icon mode).
        let regularWidth: CGFloat?
        let didChangeMode: Bool
    }

    /// Resolves a live drag width against the current mode.
    static func resolve(
        dragWidth: CGFloat,
        currentMode: SidebarColumnDisplayMode,
        profile: SidebarColumnWidthProfile
    ) -> Resolution {
        guard dragWidth.isFinite else {
            return Resolution(
                mode: currentMode,
                width: currentMode == .icons
                    ? profile.railWidth
                    : profile.defaultRegularWidth,
                regularWidth: currentMode == .icons ? nil : profile.defaultRegularWidth,
                didChangeMode: false
            )
        }
        switch currentMode {
        case .regular:
            if dragWidth < profile.iconEnterThreshold {
                return Resolution(
                    mode: .icons,
                    width: profile.railWidth,
                    regularWidth: nil,
                    didChangeMode: true
                )
            }
            let clamped = profile.clampedRegularWidth(dragWidth)
            return Resolution(
                mode: .regular,
                width: clamped,
                regularWidth: clamped,
                didChangeMode: false
            )
        case .icons:
            if dragWidth > profile.iconExitThreshold {
                let clamped = profile.clampedRegularWidth(dragWidth)
                return Resolution(
                    mode: .regular,
                    width: clamped,
                    regularWidth: clamped,
                    didChangeMode: true
                )
            }
            return Resolution(
                mode: .icons,
                width: profile.railWidth,
                regularWidth: nil,
                didChangeMode: false
            )
        }
    }

    /// Effective on-screen width for a persisted (mode, regular width) pair.
    static func effectiveWidth(
        mode: SidebarColumnDisplayMode,
        regularWidth: CGFloat,
        profile: SidebarColumnWidthProfile
    ) -> CGFloat {
        switch mode {
        case .regular: return profile.clampedRegularWidth(regularWidth)
        case .icons: return profile.railWidth
        }
    }
}

/// Reference box for body-called caches (same pattern as the sidebar row
/// snapshot cache): tracks the display mode last applied to the AppKit
/// table without registering a SwiftUI dependency.
@MainActor
final class SidebarDisplayModeBox {
    var value: SidebarColumnDisplayMode = .regular
}
