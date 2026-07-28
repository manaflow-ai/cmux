import SwiftUI

/// Renders the hover, press, disabled, and selected states of a title-bar button.
struct TitlebarControlButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color
    let isSelected: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .frame(width: config.buttonSize, height: config.buttonSize)
            .foregroundStyle(foregroundColor.opacity(foregroundOpacity))
            .background {
                if backgroundOpacity > 0 {
                    RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                        .fill(foregroundColor.opacity(backgroundOpacity))
                } else if config.buttonBackground {
                    RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                }
            }
            .overlay {
                if borderOpacity > 0 {
                    RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                        .stroke(foregroundColor.opacity(borderOpacity), lineWidth: 0.5)
                }
            }
            .scaleEffect(titlebarControlPressedScale(isPressed: configuration.isPressed))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .contentShape(Rectangle())
            .onHover { hovering in
                if titlebarControlsShouldTrackButtonHover(config: config) {
                    isHovering = hovering
                }
            }
    }

    private var foregroundOpacity: Double {
        if isSelected && isEnabled {
            return HeaderChromeIconStyle.pressedOpacity
        }
        return titlebarControlForegroundOpacity(
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
    }

    private var backgroundOpacity: Double {
        let baseOpacity = titlebarControlBackgroundOpacity(
            config: config,
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
        let activeHoverOpacity = titlebarControlActiveHoverBackgroundOpacity(
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
        let selectedOpacity = isSelected && isEnabled ? 0.12 : 0
        return max(baseOpacity, activeHoverOpacity, selectedOpacity)
    }

    private var borderOpacity: Double {
        titlebarControlBorderOpacity(
            config: config,
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
    }
}
