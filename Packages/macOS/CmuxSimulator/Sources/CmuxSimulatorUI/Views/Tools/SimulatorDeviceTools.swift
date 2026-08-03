import AppKit
import CmuxSimulator

@MainActor
final class SimulatorDeviceTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let deviceDetails = NSStackView()
    private let hardwareButtons: [SimulatorClosureButton]
    private let memoryWarningButton: SimulatorClosureButton
    private let shutdownButton: SimulatorClosureButton

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        let side = SimulatorClosureButton(
            title: String(localized: simulatorStrings.sideButton),
            imageName: "button.programmable",
            handler: { [weak coordinator] in coordinator?.press(.sideButton) }
        )
        let volumeUp = SimulatorClosureButton(
            title: String(localized: simulatorStrings.volumeUp),
            imageName: "speaker.plus",
            handler: { [weak coordinator] in coordinator?.press(.volumeUp) }
        )
        let volumeDown = SimulatorClosureButton(
            title: String(localized: simulatorStrings.volumeDown),
            imageName: "speaker.minus",
            handler: { [weak coordinator] in coordinator?.press(.volumeDown) }
        )
        hardwareButtons = [side, volumeUp, volumeDown]
        memoryWarningButton = SimulatorClosureButton(
            title: String(localized: simulatorStrings.memoryWarning),
            handler: { [weak coordinator] in coordinator?.sendMemoryWarning() }
        )
        shutdownButton = SimulatorClosureButton(
            title: String(localized: simulatorStrings.shutdown),
            handler: { [weak coordinator] in coordinator?.shutdownSelectedDevice() }
        )
        super.init(simulatorStrings.device)
        deviceDetails.orientation = .vertical
        deviceDetails.alignment = .leading
        deviceDetails.spacing = 4
        add(deviceDetails)
        add(simulatorRow(hardwareButtons))
        let swipeHome = SimulatorClosureButton(
            title: String(localized: simulatorStrings.swipeHome),
            handler: { [weak coordinator] in coordinator?.press(.swipeHome) }
        )
        let siri = SimulatorClosureButton(
            title: String(localized: simulatorStrings.siri),
            handler: { [weak coordinator] in coordinator?.press(.siri) }
        )
        add(simulatorRow([swipeHome, siri]))
        add(memoryWarningButton)
#if DEBUG
        add(SimulatorClosureButton(
            title: String(localized: simulatorStrings.terminateRenderer),
            handler: { [weak coordinator] in coordinator?.terminateRenderer() }
        ))
#endif
        addDiagnostic(simulatorStrings.colorBlendedLayers, diagnostic: .blended)
        addDiagnostic(simulatorStrings.colorCopiedImages, diagnostic: .copies)
        addDiagnostic(simulatorStrings.colorMisalignedImages, diagnostic: .misaligned)
        addDiagnostic(simulatorStrings.colorOffscreenRendering, diagnostic: .offscreen)
        addDiagnostic(simulatorStrings.slowAnimations, diagnostic: .slowAnimations)
        shutdownButton.contentTintColor = .systemRed
        add(shutdownButton)
        for button in [swipeHome, siri] { hardwareButtonsEnabled.append(button) }
    }

    private var hardwareButtonsEnabled: [SimulatorClosureButton] = []

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        deviceDetails.arrangedSubviews.forEach { deviceDetails.removeArrangedSubview($0); $0.removeFromSuperview() }
        if let device = coordinator.selectedDevice {
            for row in [
                simulatorValueRow(simulatorStrings.runtime, value: device.runtimeName),
                simulatorValueRow(
                    simulatorStrings.state,
                    value: String(localized: simulatorStrings.deviceState(device.state))
                ),
                simulatorValueRow(simulatorStrings.udid, value: device.id),
            ] {
                deviceDetails.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: deviceDetails.widthAnchor).isActive = true
            }
        }
        let hardwareEnabled = coordinator.supports(.hardwareButtons)
        (hardwareButtons + hardwareButtonsEnabled).forEach { $0.isEnabled = hardwareEnabled }
        memoryWarningButton.isEnabled = coordinator.supports(.memoryWarning)
        shutdownButton.isEnabled = coordinator.selectedDevice != nil
    }

    private func addDiagnostic(_ title: LocalizedStringResource, diagnostic: SimulatorCADiagnostic) {
        let control = SimulatorClosureSwitch(title: String(localized: title)) { [weak coordinator] enabled in
            coordinator?.setCoreAnimationDiagnostic(diagnostic, enabled: enabled)
        }
        add(control)
    }
}
