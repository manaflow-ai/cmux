import Foundation

extension SimulatorControlService {
    /// Performs one typed `simctl` action and returns its structured result.
    public func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        switch action {
        case .interactive:
            throw SimulatorControlError(
                code: "worker_only_action",
                arguments: [],
                message: String(
                    localized: "simulator.control.nativeInputRequiresWorker",
                    defaultValue: "Native input actions require the isolated Simulator worker."
                )
            )
        case let .listApplications(deviceID):
            return .applications(try await listApplications(deviceID: deviceID))
        case let .installApplication(deviceID, applicationURL):
            try await installApplication(deviceID: deviceID, applicationURL: applicationURL)
        case let .launchApplication(deviceID, bundleIdentifier, configuration):
            return .processIdentifier(try await launchApplication(
                deviceID: deviceID,
                bundleIdentifier: bundleIdentifier,
                configuration: configuration
            ))
        case let .terminateApplication(deviceID, bundleIdentifier):
            try await terminateApplication(deviceID: deviceID, bundleIdentifier: bundleIdentifier)
        case let .cleanupCameraApplication(deviceID, bundleIdentifier, ownershipToken):
            try await cleanupCameraApplication(
                deviceID: deviceID,
                bundleIdentifier: bundleIdentifier,
                ownershipToken: ownershipToken
            )
        case let .openURL(deviceID, url):
            try await openURL(deviceID: deviceID, url: url)
        case let .addMedia(deviceID, urls):
            try await addMedia(deviceID: deviceID, urls: urls)
        case let .readClipboard(deviceID):
            return .text(try await clipboardText(deviceID: deviceID))
        case let .writeClipboard(deviceID, text):
            try await setClipboardText(text, deviceID: deviceID)
        case let .syncClipboardFromHost(deviceID):
            try await syncClipboardFromHost(deviceID: deviceID)
        case let .setLocation(deviceID, coordinate):
            try await setLocation(deviceID: deviceID, coordinate: coordinate)
        case let .clearLocation(deviceID):
            try await clearLocation(deviceID: deviceID)
        case let .startLocationRoute(deviceID, route):
            try await startLocationRoute(deviceID: deviceID, route: route)
        case let .pushNotification(deviceID, bundleIdentifier, payloadURL):
            try await sendPushNotification(
                deviceID: deviceID,
                bundleIdentifier: bundleIdentifier,
                payloadURL: payloadURL
            )
        case let .setPrivacy(deviceID, action, service, bundleIdentifier):
            try await setPrivacy(
                deviceID: deviceID,
                action: action,
                service: service,
                bundleIdentifier: bundleIdentifier
            )
        case .readPrivacy, .reloadReactNative, .readAccessibility,
             .readForegroundApplication, .setAccessibilityHighlight,
             .readInterfaceStatus,
             .setCameraMirror, .readCameraStatus, .switchCameraSource,
             .refreshWebInspectorTargets, .attachWebInspector,
             .releaseWebInspector, .setWebInspectorHighlight,
             .sendWebInspectorMessage:
            throw SimulatorControlError(
                code: "worker_only_action",
                arguments: [],
                message: String(
                    localized: "simulator.control.correlatedActionRequiresWorker",
                    defaultValue: "This action requires correlated execution in the isolated Simulator worker."
                )
            )
        case let .overrideStatusBar(deviceID, values):
            try await overrideStatusBar(deviceID: deviceID, values: values)
        case let .clearStatusBar(deviceID):
            try await clearStatusBar(deviceID: deviceID)
        case let .setInterface(deviceID, setting):
            try await setInterface(deviceID: deviceID, setting: setting)
        case let .screenshot(deviceID, destinationURL, format):
            try await screenshot(deviceID: deviceID, destinationURL: destinationURL, format: format)
        case let .prepareVideoRecording(deviceID, destinationURL, codec):
            return .command(videoRecordingCommand(
                deviceID: deviceID,
                destinationURL: destinationURL,
                codec: codec
            ))
        case let .recentLogs(deviceID, bundleIdentifier, seconds):
            return .text(try await recentLogs(
                deviceID: deviceID,
                bundleIdentifier: bundleIdentifier,
                seconds: seconds
            ))
        case let .prepareLogStream(deviceID, bundleIdentifier):
            return .command(logStreamCommand(
                deviceID: deviceID,
                bundleIdentifier: bundleIdentifier
            ))
        case let .pauseLocationRoute(deviceID):
            try await pauseLocationRoute(deviceID: deviceID)
        case let .resumeLocationRoute(deviceID):
            try await resumeLocationRoute(deviceID: deviceID)
        case let .stopLocationRoute(deviceID):
            try await stopLocationRoute(deviceID: deviceID)
        case .configureCamera:
            throw SimulatorControlError(
                code: "worker_only_action",
                arguments: [],
                message: String(
                    localized: "simulator.control.cameraRequiresWorker",
                    defaultValue: "Camera injection must run inside the isolated Simulator worker."
                )
            )
        }
        return .none
    }

}
