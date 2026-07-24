import AppKit
import CmuxSettings
import SwiftUI

@MainActor
public struct TerminalFaceConfigurationEditor: View {
    @Binding private var configuration: TerminalFaceConfiguration

    public init(configuration: Binding<TerminalFaceConfiguration>) {
        _configuration = configuration
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle(
                    String(localized: "settings.terminal.face.enabled", defaultValue: "Show terminal face"),
                    isOn: $configuration.enabled
                )
                Spacer()
                Toggle(
                    String(localized: "settings.terminal.face.agentReactions", defaultValue: "React to agents"),
                    isOn: $configuration.reactsToAgents
                )
            }

            Picker(
                String(localized: "settings.terminal.face.animation", defaultValue: "Animation"),
                selection: Binding(
                    get: { configuration.animation },
                    set: { configuration.animation = $0 }
                )
            ) {
                Text(String(localized: "settings.terminal.face.animation.off", defaultValue: "Off"))
                    .tag(TerminalFaceAnimation.off)
                Text(String(localized: "settings.terminal.face.animation.visible", defaultValue: "Visible panes"))
                    .tag(TerminalFaceAnimation.whenVisible)
                Text(String(localized: "settings.terminal.face.animation.always", defaultValue: "Always"))
                    .tag(TerminalFaceAnimation.always)
            }
            .pickerStyle(.segmented)

            slider(
                String(localized: "settings.terminal.face.opacity", defaultValue: "Opacity"),
                value: $configuration.opacity,
                range: 0...1
            )
            slider(
                String(localized: "settings.terminal.face.glow", defaultValue: "Glow"),
                value: $configuration.glow,
                range: 0...1
            )
            slider(
                String(localized: "settings.terminal.face.scale", defaultValue: "Scale"),
                value: $configuration.scale,
                range: 0.25...1
            )
            slider(
                String(localized: "settings.terminal.face.horizontalPosition", defaultValue: "Horizontal position"),
                value: $configuration.horizontalPosition,
                range: 0...1
            )
            slider(
                String(localized: "settings.terminal.face.verticalPosition", defaultValue: "Vertical position"),
                value: $configuration.verticalPosition,
                range: 0...1
            )
            slider(
                String(localized: "settings.terminal.face.characterDensity", defaultValue: "Character density"),
                value: $configuration.characterDensity,
                range: 0...1
            )
            slider(
                String(localized: "settings.terminal.face.motion", defaultValue: "Motion"),
                value: $configuration.motion,
                range: 0...1
            )
            slider(
                String(localized: "settings.terminal.face.gaze", defaultValue: "Gaze"),
                value: $configuration.gaze,
                range: 0...1
            )

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                colorField(String(localized: "settings.terminal.face.color.idle", defaultValue: "Idle"), text: $configuration.idleColor)
                colorField(String(localized: "settings.terminal.face.color.thinking", defaultValue: "Thinking"), text: $configuration.thinkingColor)
                colorField(String(localized: "settings.terminal.face.color.working", defaultValue: "Working"), text: $configuration.workingColor)
                colorField(String(localized: "settings.terminal.face.color.done", defaultValue: "Done"), text: $configuration.doneColor)
                colorField(String(localized: "settings.terminal.face.color.needsInput", defaultValue: "Needs input"), text: $configuration.needsInputColor)
                colorField(String(localized: "settings.terminal.face.color.error", defaultValue: "Error"), text: $configuration.errorColor)
            }
        }
        .accessibilityIdentifier("TerminalFaceConfigurationEditor")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func colorField(_ title: String, text: Binding<String>) -> some View {
        GridRow {
            Text(title)
            HStack(spacing: 4) {
                TerminalFaceColorWell(hex: text)
                    .accessibilityLabel(title)
                TextField(
                    String(localized: "settings.terminal.face.color.placeholder", defaultValue: "#RRGGBB"),
                    text: text
                )
                .accessibilityLabel(title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 104)
            }
        }
    }
}

@MainActor
private struct TerminalFaceColorWell: NSViewRepresentable {
    @Binding var hex: String

    func makeCoordinator() -> Coordinator {
        Coordinator(hex: $hex)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 38, height: 24))
        colorWell.target = context.coordinator
        colorWell.action = #selector(Coordinator.colorChanged(_:))
        colorWell.color = Self.color(from: hex)
        return colorWell
    }

    func updateNSView(_ colorWell: NSColorWell, context: Context) {
        context.coordinator.hex = $hex
        let resolved = Self.color(from: hex)
        if colorWell.color.usingColorSpace(.sRGB) != resolved.usingColorSpace(.sRGB) {
            colorWell.color = resolved
        }
    }

    private static func color(from hex: String) -> NSColor {
        guard hex.count == 7, hex.first == "#", let value = UInt64(hex.dropFirst(), radix: 16) else {
            return .white
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var hex: Binding<String>

        init(hex: Binding<String>) {
            self.hex = hex
        }

        @objc func colorChanged(_ sender: NSColorWell) {
            guard let color = sender.color.usingColorSpace(.sRGB) else { return }
            let red = Int((color.redComponent * 255).rounded())
            let green = Int((color.greenComponent * 255).rounded())
            let blue = Int((color.blueComponent * 255).rounded())
            hex.wrappedValue = String(format: "#%02X%02X%02X", red, green, blue)
        }
    }
}
