import AppKit
import Bonsplit
import Combine
import SwiftUI


// MARK: - Titlebar control button & button style
struct TitlebarControlButton<Content: View>: View {
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let action: () -> Void
    var isEnabled = true
    var rightClickAction: ((NSView, NSEvent) -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
        }
        .disabled(!isEnabled)
        .buttonStyle(TitlebarControlButtonStyle(config: config, foregroundColor: foregroundColor))
        .frame(width: config.buttonSize, height: config.buttonSize)
        .background(TitlebarChromeGeometryReporter(keyPrefix: accessibilityIdentifier.replacingOccurrences(of: ".", with: "_")))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .overlay {
            if let rightClickAction {
                TitlebarControlRightClickView(onRightMouseDown: rightClickAction)
            }
        }
        .titlebarInteractiveControl()
    }
}

struct FocusHistoryNavigationAvailability: Equatable {
    let canNavigateBack: Bool
    let canNavigateForward: Bool

    static let unavailable = FocusHistoryNavigationAvailability(
        canNavigateBack: false,
        canNavigateForward: false
    )
}

@MainActor
func focusHistoryNavigationAvailability(preferredWindow: NSWindow?) -> FocusHistoryNavigationAvailability {
    guard let manager = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: preferredWindow) else {
        return .unavailable
    }
    return FocusHistoryNavigationAvailability(
        canNavigateBack: manager.canNavigateBack,
        canNavigateForward: manager.canNavigateForward
    )
}

private struct TitlebarControlButtonStyle: ButtonStyle {
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color

    func makeBody(configuration: Configuration) -> some View {
        TitlebarControlButtonStyleBody(
            configuration: configuration,
            config: config,
            foregroundColor: foregroundColor
        )
    }
}

private struct TitlebarControlButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color
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
        titlebarControlForegroundOpacity(
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
    }

    private var backgroundOpacity: Double {
        titlebarControlBackgroundOpacity(
            config: config,
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
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

private struct TitlebarControlRightClickView: NSViewRepresentable {
    let onRightMouseDown: (NSView, NSEvent) -> Void

    func makeNSView(context: Context) -> TitlebarControlRightClickNSView {
        let view = TitlebarControlRightClickNSView()
        view.onRightMouseDown = onRightMouseDown
        return view
    }

    func updateNSView(_ nsView: TitlebarControlRightClickNSView, context: Context) {
        nsView.onRightMouseDown = onRightMouseDown
    }
}

private final class TitlebarControlRightClickNSView: NSView {
    var onRightMouseDown: ((NSView, NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point),
              NSApp.currentEvent?.type == .rightMouseDown else {
            return nil
        }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(self, event)
    }
}

