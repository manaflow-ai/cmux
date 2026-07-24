import CmuxSimulator
import SwiftUI

struct SimulatorCameraTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorCameraToolsContent(coordinator: coordinator)
            .id(coordinator.selectedDeviceID)
    }
}

private struct SimulatorCameraToolsContent: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var targetBundleIdentifier = ""
    @State private var mirrorMode: SimulatorCameraMirrorMode = .auto
    @State private var hostCameraID = ""

    var body: some View {
        let applicationRows = simulatorApplicationPickerRows(coordinator.userInstalledApplications)
        SimulatorToolSection(simulatorStrings.cameraExperimental) {
            Text(simulatorStrings.experimentalHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !applicationRows.isEmpty {
                Picker(simulatorStrings.bundleIdentifier, selection: $targetBundleIdentifier) {
                    Text(simulatorStrings.foregroundApp).tag("")
                    ForEach(applicationRows) { application in
                        Text(verbatim: application.displayName).tag(application.id)
                    }
                }
            }
            Picker(simulatorStrings.cameraMirror, selection: $mirrorMode) {
                Text(simulatorStrings.cameraMirrorAuto).tag(SimulatorCameraMirrorMode.auto)
                Text(simulatorStrings.cameraMirrorOn).tag(SimulatorCameraMirrorMode.on)
                Text(simulatorStrings.cameraMirrorOff).tag(SimulatorCameraMirrorMode.off)
            }
            .onChange(of: mirrorMode) { _, mode in
                guard coordinator.cameraStatus?.mirrorMode != mode else { return }
                coordinator.scheduleControlAction("camera-mirror") { await $0.setCameraMirror(mode) }
            }
            if let status = coordinator.cameraStatus, !status.hostCameras.isEmpty {
                Picker(simulatorStrings.hostCameraDevice, selection: $hostCameraID) {
                    ForEach(status.hostCameras) { camera in
                        Text(verbatim: camera.name).tag(camera.id)
                    }
                }
            }
            if let status = coordinator.cameraStatus {
                LabeledContent(
                    String(localized: simulatorStrings.cameraSource),
                    value: sourceDescription(status.configuration)
                )
                LabeledContent(
                    String(localized: simulatorStrings.injectedApplications),
                    value: status.injectedBundleIdentifiers.isEmpty
                        ? String(localized: simulatorStrings.none)
                        : status.injectedBundleIdentifiers.joined(separator: ", ")
                )
            }
            ViewThatFits {
                HStack { cameraButtons }
                VStack(alignment: .leading) { cameraButtons }
            }
        }
        .task {
            await coordinator.refreshCameraStatus()
            synchronize(from: coordinator.cameraStatus)
        }
        .onChange(of: coordinator.cameraStatus) { _, status in
            synchronize(from: status)
        }
        .onChange(of: coordinator.userInstalledApplications) { _, applications in
            targetBundleIdentifier = simulatorCameraTargetBundleIdentifier(
                current: targetBundleIdentifier,
                applications: applications
            )
        }
    }

    private var cameraButtons: some View {
        Group {
            Button(simulatorStrings.chooseCameraSource) {
                coordinator.scheduleControlAction("camera-source") {
                    await $0.chooseCameraSource(
                        targetBundleIdentifier: targetBundleIdentifier
                    )
                }
            }
            Button(simulatorStrings.cameraPlaceholder) {
                coordinator.scheduleControlAction("camera-source") {
                    await $0.useCameraPlaceholder(
                        targetBundleIdentifier: targetBundleIdentifier
                    )
                }
            }
            Button(simulatorStrings.hostCamera) {
                coordinator.scheduleControlAction("camera-source") {
                    await $0.useHostCamera(
                        deviceID: hostCameraID.isEmpty ? nil : hostCameraID,
                        targetBundleIdentifier: targetBundleIdentifier
                    )
                    await $0.setCameraMirror(mirrorMode)
                }
            }
            Button(simulatorStrings.disableCamera) {
                coordinator.scheduleControlAction("camera-source") { await $0.disableCamera() }
            }
            Button(simulatorStrings.refresh) {
                coordinator.scheduleControlAction("refresh-camera") { await $0.refreshCameraStatus() }
            }
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

    private func synchronize(from status: SimulatorCameraStatus?) {
        guard let status else { return }
        mirrorMode = status.mirrorMode
        let configuredDeviceID = hostDeviceID(in: status.configuration)
        if let configuredDeviceID,
           status.hostCameras.contains(where: { $0.id == configuredDeviceID }) {
            hostCameraID = configuredDeviceID
        } else if !status.hostCameras.contains(where: { $0.id == hostCameraID }) {
            hostCameraID = status.hostCameras.first?.id ?? ""
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
