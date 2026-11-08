import CmuxControlSocket
import CmuxSimulator
import CmuxSimulatorUI
import Foundation

extension TerminalController {
    func simulatorCameraConfiguration(
        source: String,
        path: String?,
        loops: Bool,
        hostDeviceID: String?,
        bundleIdentifier: String?
    ) async throws -> SimulatorCameraConfiguration {
        let base: SimulatorCameraConfiguration
        switch source {
        case "off", "disabled": base = .disabled
        case "placeholder": base = .placeholder
        case "image":
            guard let path else { throw simulatorCameraFailure(cameraPathRequired("image")) }
            base = .image(URL(fileURLWithPath: path))
        case "video":
            guard let path else { throw simulatorCameraFailure(cameraPathRequired("video")) }
            base = .video(URL(fileURLWithPath: path), loops: loops)
        case "file":
            guard let path else { throw simulatorCameraFailure(cameraPathRequired("file")) }
            let url = URL(fileURLWithPath: path)
            guard let classified = await SimulatorCameraSourceClassifier().configuration(for: url) else {
                throw simulatorCameraFailure(String(
                    localized: "cli.simulator.error.cameraUnreadable",
                    defaultValue: "The camera file is not a readable image or video"
                ))
            }
            if case let .video(videoURL, _) = classified {
                base = .video(videoURL, loops: loops)
            } else { base = classified }
        case "host", "webcam": base = .hostCamera(deviceID: hostDeviceID)
        default: throw simulatorCameraFailure(String.localizedStringWithFormat(
            String(
                localized: "cli.simulator.error.unknownCameraSource",
                defaultValue: "Unknown Simulator camera source: %@"
            ), source
        ))
        }
        guard let bundleIdentifier, !base.isDisabled else { return base }
        return .targeted(bundleIdentifier: bundleIdentifier, source: base)
    }

    func simulatorCameraResultPayload(_ result: SimulatorControlResult) throws -> JSONValue {
        guard case let .cameraStatus(status) = result else {
            throw simulatorCameraFailure(String(
                localized: "cli.simulator.error.cameraStatusMissing",
                defaultValue: "The Simulator worker returned no camera status"
            ))
        }
        return .object([
            "configuration": simulatorCameraConfigurationPayload(status.configuration),
            "mirror": .string(status.mirrorMode.rawValue),
            "bundle_ids": .array(status.injectedBundleIdentifiers.map(JSONValue.string)),
            "target_bundle_id": status.targetBundleIdentifier.map(JSONValue.string) ?? .null,
            "target_process_id": status.targetProcessIdentifier.map { .int(Int64($0)) } ?? .null,
            "alive": .bool(status.targetIsAlive),
            "attached": .bool(status.targetIsAttached),
            "targets": .array(status.targets.map { target in .object([
                "bundle_id": .string(target.bundleIdentifier),
                "process_id": target.processIdentifier.map { .int(Int64($0)) } ?? .null,
                "alive": .bool(target.isAlive),
                "attached": .bool(target.isAttached),
            ]) }),
            "host_cameras": .array(status.hostCameras.map { camera in .object([
                "id": .string(camera.id), "name": .string(camera.name),
            ]) }),
        ])
    }

    func simulatorCameraConfigurationPayload(
        _ configuration: SimulatorCameraConfiguration
    ) -> JSONValue {
        switch configuration {
        case .disabled: .object(["source": .string("off")])
        case .placeholder: .object(["source": .string("placeholder")])
        case let .image(url): .object(["source": .string("image"), "path": .string(url.path)])
        case let .video(url, loops): .object([
            "source": .string("video"), "path": .string(url.path), "loops": .bool(loops),
        ])
        case let .hostCamera(deviceID): .object([
            "source": .string("webcam"), "device_id": deviceID.map(JSONValue.string) ?? .null,
        ])
        case let .targeted(bundleIdentifier, source): .object([
            "bundle_id": .string(bundleIdentifier),
            "source": simulatorCameraConfigurationPayload(source),
        ])
        }
    }

    func simulatorEventPayload(_ entry: SimulatorActionLogEntry) -> JSONValue {
        .object([
            "id": .string(entry.id.uuidString),
            "timestamp": .string(entry.timestamp.ISO8601Format()),
            "action": .string(entry.action),
            "summary": .string(entry.summary),
            "succeeded": entry.succeeded.map(JSONValue.bool) ?? .null,
        ])
    }

    private func simulatorCameraFailure(_ message: String) -> SimulatorFailure {
        SimulatorFailure(code: "invalid_params", message: message, isRecoverable: true)
    }

    private func cameraPathRequired(_ source: String) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "cli.simulator.error.cameraPathRequired",
                defaultValue: "Camera source %@ requires a file path"
            ),
            source
        )
    }
}
