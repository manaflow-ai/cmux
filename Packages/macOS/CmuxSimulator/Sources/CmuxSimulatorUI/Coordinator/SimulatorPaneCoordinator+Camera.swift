import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Disables experimental camera injection.
    public func disableCamera() async {
        await configureCamera(.disabled)
    }

    /// Uses the worker's animated placeholder camera source.
    /// - Parameter targetBundleIdentifier: An optional app to target explicitly.
    public func useCameraPlaceholder(targetBundleIdentifier: String? = nil) async {
        await configureCamera(targeted(.placeholder, bundleIdentifier: targetBundleIdentifier))
    }

    /// Hot-swaps source-independent camera mirroring.
    /// - Parameter mode: Automatic, always mirrored, or never mirrored.
    public func setCameraMirror(_ mode: SimulatorCameraMirrorMode) async {
        guard (try? await perform(.setCameraMirror(mode))) != nil else { return }
        await refreshCameraStatus()
    }

    /// Reads current camera source, mirror, injection, and host-device status.
    public func refreshCameraStatus() async {
        _ = try? await perform(.readCameraStatus)
    }

    /// Presents a native picker and configures an experimental image or video
    /// camera source.
    /// - Parameter targetBundleIdentifier: An optional app to target explicitly.
    public func chooseCameraSource(targetBundleIdentifier: String? = nil) async {
        guard let url = await filePicker.chooseCameraSource() else { return }
        guard let configuration = await SimulatorCameraSourceClassifier().configuration(for: url)
        else {
            controlFailure = SimulatorFailure(
                code: "unsupported_camera_source",
                message: CocoaError(.fileReadCorruptFile).localizedDescription,
                isRecoverable: true
            )
            return
        }
        await configureCamera(targeted(configuration, bundleIdentifier: targetBundleIdentifier))
    }

    /// Uses a host camera inside the isolated worker.
    /// - Parameters:
    ///   - deviceID: The AVFoundation device identifier, or `nil` for default.
    ///   - targetBundleIdentifier: An optional app to target explicitly.
    public func useHostCamera(
        deviceID: String? = nil,
        targetBundleIdentifier: String? = nil
    ) async {
        await configureCamera(targeted(
            .hostCamera(deviceID: deviceID),
            bundleIdentifier: targetBundleIdentifier
        ))
    }

    private func configureCamera(_ configuration: SimulatorCameraConfiguration) async {
        guard (try? await perform(.configureCamera(configuration))) != nil else { return }
        cameraConfiguration = configuration
        await refreshCameraStatus()
    }

    private func targeted(
        _ configuration: SimulatorCameraConfiguration,
        bundleIdentifier: String?
    ) -> SimulatorCameraConfiguration {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return configuration }
        return .targeted(bundleIdentifier: bundleIdentifier, source: configuration)
    }
}
