public import SwiftUI

/// Fixed-size circular icon label shared by mobile composer controls.
public struct MobileComposerIconLabel: View {
    private let systemImage: String
    private let activeSystemImage: String?
    private let isActive: Bool
    private let foregroundStyle: AnyShapeStyle
    private let size: CGFloat
    private let iconSize: CGFloat
    private let pulsesWhenActive: Bool

    /// Creates a circular icon label with optional active-state artwork.
    public nonisolated init(
        systemImage: String,
        activeSystemImage: String? = nil,
        isActive: Bool = false,
        foregroundStyle: AnyShapeStyle,
        size: CGFloat = 40,
        iconSize: CGFloat = 15,
        pulsesWhenActive: Bool = false
    ) {
        self.systemImage = systemImage
        self.activeSystemImage = activeSystemImage
        self.isActive = isActive
        self.foregroundStyle = foregroundStyle
        self.size = size
        self.iconSize = iconSize
        self.pulsesWhenActive = pulsesWhenActive
    }

    /// The rendered icon and circular Liquid Glass backing.
    public var body: some View {
        Image(systemName: isActive ? activeSystemImage ?? systemImage : systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(foregroundStyle)
            .frame(width: size, height: size)
            .symbolEffect(.pulse, isActive: pulsesWhenActive && isActive)
            .mobileGlassCircle()
    }
}
