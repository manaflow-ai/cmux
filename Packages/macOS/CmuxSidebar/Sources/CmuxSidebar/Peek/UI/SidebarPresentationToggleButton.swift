public import SwiftUI

/// The one-click switch between the docked and floating sidebar.
///
/// Sits in the panel's top-trailing corner where a window control would, and
/// stays in the same place in both modes so the gesture to go back is the
/// gesture that got you here.
public struct SidebarPresentationToggleButton: View {
    /// The mode currently in effect.
    public let mode: SidebarPresentationMode
    /// The sidebar accent color.
    public let accent: Color
    /// Point size of the glyph.
    public let fontSize: CGFloat
    /// Switches to the other mode.
    public let onToggle: () -> Void

    @State private var isHovering = false

    /// Creates the toggle.
    ///
    /// - Parameters:
    ///   - mode: The mode currently in effect.
    ///   - accent: The sidebar accent color.
    ///   - fontSize: Point size of the glyph.
    ///   - onToggle: Called to switch modes.
    public init(
        mode: SidebarPresentationMode,
        accent: Color,
        fontSize: CGFloat = 11,
        onToggle: @escaping () -> Void
    ) {
        self.mode = mode
        self.accent = accent
        self.fontSize = fontSize
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: onToggle) {
            Image(systemName: glyph)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(isHovering ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier("SidebarPresentationToggle")
    }

    /// Shows the mode being switched *to*, not the mode in effect: the button
    /// is a door, and a door is labelled with where it leads.
    ///
    /// Both glyphs are drawn from the same `sidebar.*` family so the control
    /// reads as one switch with two positions. A pushpin would say "keep this",
    /// which is not what docking does to the layout.
    private var glyph: String {
        mode.isFloating ? "sidebar.leading" : "macwindow"
    }

    private var helpText: String {
        mode.isFloating
            ? String(localized: "sidebar.presentation.dock", defaultValue: "Dock sidebar")
            : String(localized: "sidebar.presentation.float", defaultValue: "Float sidebar")
    }
}
