import CmuxAndroidEmulator
import SwiftUI

struct AndroidEmulatorControlRail: View {
    let controller: AndroidEmulatorPaneController

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                control("xmark", label: String(localized: "androidEmulator.control.stop", defaultValue: "Stop Emulator", bundle: .module)) {
                    controller.stop()
                }
                control("minus", label: String(localized: "androidEmulator.control.collapse", defaultValue: "Hide Controls", bundle: .module)) {
                    controller.controlsCollapsed = true
                }
                Divider()
                action("power", label: String(localized: "androidEmulator.control.power", defaultValue: "Power", bundle: .module), .power)
                action("speaker.wave.3", label: String(localized: "androidEmulator.control.volumeUp", defaultValue: "Volume Up", bundle: .module), .volumeUp)
                action("speaker.wave.1", label: String(localized: "androidEmulator.control.volumeDown", defaultValue: "Volume Down", bundle: .module), .volumeDown)
                control("camera", label: String(localized: "androidEmulator.control.screenshot", defaultValue: "Take Screenshot", bundle: .module)) {
                    controller.saveScreenshot()
                }
                control("plus.magnifyingglass", label: String(localized: "androidEmulator.control.zoom", defaultValue: "Zoom", bundle: .module)) {
                    controller.cycleZoom()
                }
                action("rotate.left", label: String(localized: "androidEmulator.control.rotateLeft", defaultValue: "Rotate Left", bundle: .module), .rotateLeft)
                action("rotate.right", label: String(localized: "androidEmulator.control.rotateRight", defaultValue: "Rotate Right", bundle: .module), .rotateRight)
                Divider()
                action("chevron.backward", label: String(localized: "androidEmulator.control.back", defaultValue: "Back", bundle: .module), .back)
                action("circle", label: String(localized: "androidEmulator.control.home", defaultValue: "Home", bundle: .module), .home)
                action("square", label: String(localized: "androidEmulator.control.overview", defaultValue: "Overview", bundle: .module), .overview)
                Divider()
                control("ellipsis", label: String(localized: "androidEmulator.control.more", defaultValue: "More Controls", bundle: .module)) {
                    controller.showVendorControls()
                }
            }
            .padding(8)
        }
        .frame(width: 54)
        .background(.bar)
    }

    private func action(
        _ symbol: String,
        label: String,
        _ action: AndroidEmulatorControlAction
    ) -> some View {
        control(symbol, label: label) {
            controller.perform(action)
        }
    }

    private func control(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
        .help(label)
    }
}
