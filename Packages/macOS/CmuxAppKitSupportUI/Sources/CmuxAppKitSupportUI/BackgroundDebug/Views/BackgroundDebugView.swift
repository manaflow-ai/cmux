#if canImport(AppKit)
#if DEBUG

public import SwiftUI

internal import AppKit
internal import CmuxFoundation

/// The Background Debug panel: live controls for the main window's background
/// glass effect (enable, material, tint color, tint opacity) backed by the shared
/// `@AppStorage` keys the window-chrome composition reads (`bgGlassEnabled`,
/// `bgGlassMaterial`, `bgGlassTintHex`, `bgGlassTintOpacity`).
///
/// The view is byte-faithful to the panel that previously lived in the app
/// target. Its one irreducibly app-coupled behavior is injected: applying the
/// live tint to the running main window goes through the app-target window-chrome
/// composition (the main-window lookup plus
/// `AppWindowChromeComposition().backdropController.updateGlassTint`), so the app
/// supplies ``applyGlassTint``. The package therefore owns no reference to the
/// application delegate or the window-chrome composition.
public struct BackgroundDebugView: View {
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassMaterial") private var bgGlassMaterial = "hudWindow"
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = false

    private let applyGlassTint: @MainActor (NSColor) -> Void

    /// Creates the panel.
    ///
    /// - Parameter applyGlassTint: Applies the resolved tint color to the live
    ///   main window. The package computes the color from its `@AppStorage` keys
    ///   and hands it to this closure; the app target performs the main-window
    ///   lookup and drives the window-chrome composition, matching the legacy
    ///   app-side `updateWindowGlassTint()`.
    public init(applyGlassTint: @escaping @MainActor (NSColor) -> Void) {
        self.applyGlassTint = applyGlassTint
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Window Background Glass")
                    .font(.headline)

                GroupBox("Glass Effect") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Glass Effect", isOn: $bgGlassEnabled)

                        Picker("Material", selection: $bgGlassMaterial) {
                            Text("HUD Window").tag("hudWindow")
                            Text("Under Window").tag("underWindowBackground")
                            Text("Sidebar").tag("sidebar")
                            Text("Menu").tag("menu")
                            Text("Popover").tag("popover")
                        }
                        .disabled(!bgGlassEnabled)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Tint") {
                    VStack(alignment: .leading, spacing: 8) {
                        ColorPicker("Tint Color", selection: tintColorBinding, supportsOpacity: false)
                            .disabled(!bgGlassEnabled)

                        HStack(spacing: 8) {
                            Text("Opacity")
                            Slider(value: $bgGlassTintOpacity, in: 0...0.8)
                                .disabled(!bgGlassEnabled)
                            Text(String(format: "%.0f%%", bgGlassTintOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button("Reset") {
                        bgGlassTintHex = "#000000"
                        bgGlassTintOpacity = 0.03
                        bgGlassMaterial = "hudWindow"
                        bgGlassEnabled = false
                        updateWindowGlassTint()
                    }

                    Button("Copy Config") {
                        copyBgConfig()
                    }
                }

                Text("Tint changes apply live. Enable/disable requires reload.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: bgGlassTintHex) { _ in updateWindowGlassTint() }
        .onChange(of: bgGlassTintOpacity) { _ in updateWindowGlassTint() }
    }

    private func updateWindowGlassTint() {
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        applyGlassTint(tintColor)
    }

    private var tintColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: bgGlassTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                bgGlassTintHex = nsColor.hexString()
            }
        )
    }

    private func copyBgConfig() {
        let payload = """
        bgGlassEnabled=\(bgGlassEnabled)
        bgGlassMaterial=\(bgGlassMaterial)
        bgGlassTintHex=\(bgGlassTintHex)
        bgGlassTintOpacity=\(String(format: "%.2f", bgGlassTintOpacity))
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
}

#endif
#endif
