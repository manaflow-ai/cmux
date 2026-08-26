import CmuxSimulator
import SwiftUI

struct SimulatorDeviceTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var colorBlendedLayers = false
    @State private var colorCopiedImages = false
    @State private var colorMisalignedImages = false
    @State private var colorOffscreenRendering = false
    @State private var slowAnimations = false

    var body: some View {
        SimulatorToolSection(simulatorStrings.device) {
            if let device = coordinator.selectedDevice {
                LabeledContent(String(localized: simulatorStrings.runtime), value: device.runtimeName)
                LabeledContent(
                    String(localized: simulatorStrings.state),
                    value: String(localized: simulatorStrings.deviceState(device.state))
                )
                LabeledContent(String(localized: simulatorStrings.udid), value: device.id)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            ViewThatFits {
                HStack { hardwareButtons }
                VStack(alignment: .leading) { hardwareButtons }
            }
            HStack {
                SimulatorLocalizedButton(simulatorStrings.swipeHome) { coordinator.press(.swipeHome) }
                SimulatorLocalizedButton(simulatorStrings.siri) { coordinator.press(.siri) }
            }
            .disabled(!coordinator.supports(.hardwareButtons))
            SimulatorLocalizedButton(simulatorStrings.memoryWarning) { coordinator.sendMemoryWarning() }
                .disabled(!coordinator.supports(.memoryWarning))
#if DEBUG
            SimulatorDebugTools(coordinator: coordinator)
#endif
            SimulatorLocalizedToggle(simulatorStrings.colorBlendedLayers, isOn: $colorBlendedLayers)
                .onChange(of: colorBlendedLayers) { _, enabled in
                    coordinator.setCoreAnimationDiagnostic(.blended, enabled: enabled)
                }
            SimulatorLocalizedToggle(simulatorStrings.colorCopiedImages, isOn: $colorCopiedImages)
                .onChange(of: colorCopiedImages) { _, enabled in
                    coordinator.setCoreAnimationDiagnostic(.copies, enabled: enabled)
                }
            SimulatorLocalizedToggle(simulatorStrings.colorMisalignedImages, isOn: $colorMisalignedImages)
                .onChange(of: colorMisalignedImages) { _, enabled in
                    coordinator.setCoreAnimationDiagnostic(.misaligned, enabled: enabled)
                }
            SimulatorLocalizedToggle(simulatorStrings.colorOffscreenRendering, isOn: $colorOffscreenRendering)
                .onChange(of: colorOffscreenRendering) { _, enabled in
                    coordinator.setCoreAnimationDiagnostic(.offscreen, enabled: enabled)
                }
            SimulatorLocalizedToggle(simulatorStrings.slowAnimations, isOn: $slowAnimations)
                .onChange(of: slowAnimations) { _, enabled in
                    coordinator.setCoreAnimationDiagnostic(.slowAnimations, enabled: enabled)
                }
            SimulatorLocalizedButton(simulatorStrings.shutdown, role: .destructive) {
                coordinator.shutdownSelectedDevice()
            }
            .disabled(coordinator.selectedDevice == nil)
        }
    }

    private var hardwareButtons: some View {
        Group {
            Button { coordinator.press(.sideButton) } label: {
                SimulatorLocalizedLabel(simulatorStrings.sideButton, systemImage: "button.programmable")
            }
            Button { coordinator.press(.volumeUp) } label: {
                SimulatorLocalizedLabel(simulatorStrings.volumeUp, systemImage: "speaker.plus")
            }
            Button { coordinator.press(.volumeDown) } label: {
                SimulatorLocalizedLabel(simulatorStrings.volumeDown, systemImage: "speaker.minus")
            }
        }
        .disabled(!coordinator.supports(.hardwareButtons))
    }
}
