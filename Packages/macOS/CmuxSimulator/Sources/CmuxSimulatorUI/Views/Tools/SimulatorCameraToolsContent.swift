import AppKit
import CmuxSimulator

@MainActor
class SimulatorCameraToolsContent: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let targetPicker = SimulatorClosurePopUpButton()
    private let mirrorPicker = SimulatorClosurePopUpButton()
    private let hostCameraPicker = SimulatorClosurePopUpButton()
    private let sourceLabel = simulatorLabel("")
    private let injectedLabel = simulatorLabel("")
    private let mirrorModes: [SimulatorCameraMirrorMode] = [.auto, .on, .off]
    private var targetIDs = [String]()
    private var hostCameraIDs = [String]()
    private var selectedTargetID = ""
    private var lastHydratedDeviceID: String?
    private var isSynchronizing = false

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.cameraExperimental)
        add(simulatorLabel(
            String(localized: simulatorStrings.experimentalHelp),
            color: .secondaryLabelColor
        ))
        targetPicker.handler = { [weak self] index in
            guard let self, targetIDs.indices.contains(index) else { return }
            selectedTargetID = targetIDs[index]
        }
        add(targetPicker)
        mirrorPicker.addItems(withTitles: [
            String(localized: simulatorStrings.cameraMirrorAuto),
            String(localized: simulatorStrings.cameraMirrorOn),
            String(localized: simulatorStrings.cameraMirrorOff),
        ])
        mirrorPicker.handler = { [weak self] index in
            guard let self, !isSynchronizing, mirrorModes.indices.contains(index) else { return }
            let mode = mirrorModes[index]
            coordinator.scheduleControlAction("camera-mirror") { await $0.setCameraMirror(mode) }
        }
        add(labeled(simulatorStrings.cameraMirror, mirrorPicker))
        add(labeled(simulatorStrings.hostCameraDevice, hostCameraPicker))
        add(labeled(simulatorStrings.cameraSource, sourceLabel))
        add(labeled(simulatorStrings.injectedApplications, injectedLabel))
        let choose = SimulatorClosureButton(title: String(localized: simulatorStrings.chooseCameraSource)) {
            [weak self] in self?.chooseSource()
        }
        let placeholder = SimulatorClosureButton(title: String(localized: simulatorStrings.cameraPlaceholder)) {
            [weak self] in self?.usePlaceholder()
        }
        let host = SimulatorClosureButton(title: String(localized: simulatorStrings.hostCamera)) {
            [weak self] in self?.useHostCamera()
        }
        let disable = SimulatorClosureButton(title: String(localized: simulatorStrings.disableCamera)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("camera-source") { await $0.disableCamera() }
        }
        let refresh = SimulatorClosureButton(title: String(localized: simulatorStrings.refresh)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("refresh-camera") { await $0.refreshCameraStatus() }
        }
        add(simulatorRow([choose, placeholder]))
        add(simulatorRow([host, disable, refresh]))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        if lastHydratedDeviceID != coordinator.selectedDeviceID {
            lastHydratedDeviceID = coordinator.selectedDeviceID
            Task { @MainActor [weak coordinator] in await coordinator?.refreshCameraStatus() }
        }
        updateTargets()
        updateStatus()
    }

    private func updateTargets() {
        let applications = coordinator.userInstalledApplications
        selectedTargetID = simulatorCameraTargetBundleIdentifier(
            current: selectedTargetID,
            applications: applications
        )
        let nextIDs = [""] + applications.map(\.id)
        if nextIDs != targetIDs {
            targetIDs = nextIDs
            targetPicker.removeAllItems()
            targetPicker.addItem(withTitle: String(localized: simulatorStrings.foregroundApp))
            targetPicker.addItems(withTitles: applications.map(\.displayName))
            targetPicker.selectItem(at: targetIDs.firstIndex(of: selectedTargetID) ?? 0)
        }
        targetPicker.isHidden = applications.isEmpty
    }

    private func updateStatus() {
        guard let status = coordinator.cameraStatus else {
            sourceLabel.stringValue = String(localized: simulatorStrings.none)
            injectedLabel.stringValue = String(localized: simulatorStrings.none)
            hostCameraPicker.isHidden = true
            return
        }
        isSynchronizing = true
        mirrorPicker.selectItem(at: mirrorModes.firstIndex(of: status.mirrorMode) ?? 0)
        isSynchronizing = false
        let nextHostIDs = status.hostCameras.map(\.id)
        if nextHostIDs != hostCameraIDs {
            let configured = hostDeviceID(in: status.configuration)
            let previous = selectedHostCameraID
            hostCameraIDs = nextHostIDs
            hostCameraPicker.removeAllItems()
            hostCameraPicker.addItems(withTitles: status.hostCameras.map(\.name))
            let selection = configured.flatMap(hostCameraIDs.firstIndex(of:))
                ?? previous.flatMap(hostCameraIDs.firstIndex(of:))
                ?? 0
            if hostCameraIDs.indices.contains(selection) { hostCameraPicker.selectItem(at: selection) }
        }
        hostCameraPicker.isHidden = hostCameraIDs.isEmpty
        sourceLabel.stringValue = sourceDescription(status.configuration)
        injectedLabel.stringValue = status.injectedBundleIdentifiers.isEmpty
            ? String(localized: simulatorStrings.none)
            : status.injectedBundleIdentifiers.joined(separator: ", ")
    }

    private func labeled(_ title: LocalizedStringResource, _ value: NSView) -> NSStackView {
        let label = simulatorLabel(String(localized: title), color: .secondaryLabelColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return simulatorRow([label, spacer, value])
    }

    private var selectedHostCameraID: String? {
        guard hostCameraIDs.indices.contains(hostCameraPicker.indexOfSelectedItem) else { return nil }
        return hostCameraIDs[hostCameraPicker.indexOfSelectedItem]
    }

    private func chooseSource() {
        let target = selectedTargetID
        coordinator.scheduleControlAction("camera-source") {
            await $0.chooseCameraSource(targetBundleIdentifier: target)
        }
    }

    private func usePlaceholder() {
        let target = selectedTargetID
        coordinator.scheduleControlAction("camera-source") {
            await $0.useCameraPlaceholder(targetBundleIdentifier: target)
        }
    }

    private func useHostCamera() {
        let target = selectedTargetID
        let deviceID = selectedHostCameraID
        let mode = mirrorModes.indices.contains(mirrorPicker.indexOfSelectedItem)
            ? mirrorModes[mirrorPicker.indexOfSelectedItem]
            : .auto
        coordinator.scheduleControlAction("camera-source") {
            await $0.useHostCamera(deviceID: deviceID, targetBundleIdentifier: target)
            await $0.setCameraMirror(mode)
        }
    }

    private func sourceDescription(_ configuration: SimulatorCameraConfiguration) -> String {
        switch configuration {
        case .disabled:
            String(localized: simulatorStrings.cameraSourceDisabled)
        case .placeholder:
            String(localized: simulatorStrings.cameraPlaceholder)
        case let .image(url):
            url.lastPathComponent
        case let .video(url, _):
            url.lastPathComponent
        case let .hostCamera(deviceID):
            coordinator.cameraStatus?.hostCameras.first(where: { $0.id == deviceID })?.name
                ?? String(localized: simulatorStrings.hostCamera)
        case let .targeted(bundleIdentifier, source):
            "\(sourceDescription(source)) · \(bundleIdentifier)"
        }
    }

    private func hostDeviceID(in configuration: SimulatorCameraConfiguration) -> String? {
        switch configuration {
        case let .hostCamera(deviceID):
            deviceID
        case let .targeted(_, source):
            hostDeviceID(in: source)
        default:
            nil
        }
    }
}

func simulatorCameraTargetBundleIdentifier(
    current: String,
    applications: [SimulatorInstalledApplication]
) -> String {
    guard !current.isEmpty else { return "" }
    return applications.contains(where: { $0.id == current }) ? current : ""
}
