public import AppKit
public import CmuxUpdater

/// Derives native update-control colors for a given ``UpdateStateModel`` state.
@MainActor
public struct UpdateAppearance {
    /// The host accent color used for available-update emphasis.
    public let accent: NSColor

    /// Creates an appearance with the given accent color.
    public init(accent: NSColor) {
        self.accent = accent
    }

    /// The icon tint for the model's current effective state.
    public func iconColor(for model: UpdateStateModel) -> NSColor {
        if model.showsDetectedBackgroundUpdate {
            return accent
        }
        switch model.effectiveState {
        case .idle, .preparingCheck, .checking, .startingDownload,
                .downloading, .extracting, .installing, .notFound:
            return .secondaryLabelColor
        case .permissionRequest:
            return .white
        case .updateAvailable:
            return accent
        case .error:
            return .systemOrange
        }
    }

    /// The pill background fill for the model's current effective state.
    public func backgroundColor(for model: UpdateStateModel) -> NSColor {
        if model.showsDetectedBackgroundUpdate {
            return accent
        }
        switch model.effectiveState {
        case .permissionRequest:
            return NSColor.systemBlue.blended(withFraction: 0.3, of: .black) ?? .systemBlue
        case .updateAvailable:
            return accent
        case .notFound:
            return NSColor.systemBlue.blended(withFraction: 0.5, of: .black) ?? .systemBlue
        case .error:
            return NSColor.systemOrange.withAlphaComponent(0.2)
        default:
            return .controlBackgroundColor
        }
    }

    /// The pill and badge foreground tint for the model's current effective state.
    public func foregroundColor(for model: UpdateStateModel) -> NSColor {
        if model.showsDetectedBackgroundUpdate {
            return .white
        }
        switch model.effectiveState {
        case .permissionRequest, .updateAvailable, .notFound:
            return .white
        case .error:
            return .systemOrange
        default:
            return .labelColor
        }
    }
}
