public import SwiftUI

/// Shared circular glass icon button for mobile composer controls.
public struct MobileComposerIconButton: View {
    private let systemImage: String
    private let activeSystemImage: String?
    private let isActive: Bool
    private let foregroundStyle: AnyShapeStyle
    private let size: CGFloat
    private let iconSize: CGFloat
    private let pulsesWhenActive: Bool
    private let isDisabled: Bool
    private let accessibilityIdentifier: String
    private let accessibilityLabel: String
    private let action: () -> Void

    /// Creates a tappable circular icon control.
    public init(
        systemImage: String,
        activeSystemImage: String? = nil,
        isActive: Bool = false,
        foregroundStyle: AnyShapeStyle,
        size: CGFloat = 40,
        iconSize: CGFloat = 15,
        pulsesWhenActive: Bool = false,
        isDisabled: Bool = false,
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.activeSystemImage = activeSystemImage
        self.isActive = isActive
        self.foregroundStyle = foregroundStyle
        self.size = size
        self.iconSize = iconSize
        self.pulsesWhenActive = pulsesWhenActive
        self.isDisabled = isDisabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    /// The rendered button and accessibility metadata.
    public var body: some View {
        Button(action: action) {
            MobileComposerIconLabel(
                systemImage: systemImage,
                activeSystemImage: activeSystemImage,
                isActive: isActive,
                foregroundStyle: foregroundStyle,
                size: size,
                iconSize: iconSize,
                pulsesWhenActive: pulsesWhenActive
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
    }
}
