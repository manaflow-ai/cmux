public import SwiftUI
public import CmuxUpdater
import AppKit

/// Derives the update pill/badge colors for a given ``UpdateStateModel`` state.
///
/// These derivations live in the UI layer (not the domain model) because they map state to
/// SwiftUI `Color`s and depend on the host's accent color, which is injected rather than read
/// from a global. Construct one with the current accent and ask it for a color per state.
public struct UpdateAppearance: Sendable {
    /// The host accent color used for the "update available" / detected-update emphasis.
    public let accent: Color

    /// Creates an appearance with the given accent color.
    public init(accent: Color) {
        self.accent = accent
    }

    /// The icon tint for the model's current effective state.
    @MainActor
    public func iconColor(for model: UpdateStateModel) -> Color {
        if model.showsDetectedBackgroundUpdate {
            return accent
        }
        switch model.effectiveState {
        case .idle:
            return .secondary
        case .permissionRequest:
            return .white
        case .preparingCheck, .checking:
            return .secondary
        case .updateAvailable:
            return accent
        case .startingDownload, .downloading, .extracting, .installing:
            return .secondary
        case .notFound:
            return .secondary
        case .error:
            return .orange
        }
    }

    /// The pill background fill for the model's current effective state.
    @MainActor
    public func backgroundColor(for model: UpdateStateModel) -> Color {
        if model.showsDetectedBackgroundUpdate {
            return accent
        }
        switch model.effectiveState {
        case .permissionRequest:
            return Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.3, of: .black) ?? .systemBlue)
        case .updateAvailable:
            return accent
        case .notFound:
            return Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.5, of: .black) ?? .systemBlue)
        case .error:
            return .orange.opacity(0.2)
        default:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    /// The pill/badge foreground tint for the model's current effective state.
    @MainActor
    public func foregroundColor(for model: UpdateStateModel) -> Color {
        if model.showsDetectedBackgroundUpdate {
            return .white
        }
        switch model.effectiveState {
        case .permissionRequest:
            return .white
        case .updateAvailable:
            return .white
        case .notFound:
            return .white
        case .error:
            return .orange
        default:
            return .primary
        }
    }
}
