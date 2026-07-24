import AppKit
import CmuxSimulator
import Foundation

private let simulatorDroppedMediaExtensions = Set([
    "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff",
    "bmp", "mov", "mp4", "m4v", "hevc", "vcf",
])

private enum SimulatorControlActionTaskContext {
    @TaskLocal static var token: UUID?
}

extension SimulatorPaneCoordinator {
    /// Starts one pane-owned UI action. Repeated actions with the same key are
    /// coalesced, and ``close()`` cancels and joins every admitted task.
    public func scheduleControlAction(
        _ key: String,
        operation: @escaping @MainActor @Sendable (SimulatorPaneCoordinator) async -> Void
    ) {
        startControlAction(key, operation: operation)
    }

    /// Admits pane-owned work and returns its cancellation handle to callers
    /// that also own a timeout or transport receipt.
    @discardableResult
    public func startControlAction(
        _ key: String,
        operation: @escaping @MainActor @Sendable (SimulatorPaneCoordinator) async -> Void
    ) -> Task<Void, Never>? {
        guard !closed, controlActionTasks[key] == nil,
              controlActionTasks.count < 8 else { return nil }
        let token = UUID()
        controlActionTaskTokens[key] = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await SimulatorControlActionTaskContext.$token.withValue(token) {
                if !Task.isCancelled { await operation(self) }
            }
            guard self.controlActionTaskTokens[key] == token else { return }
            self.controlActionTaskTokens.removeValue(forKey: key)
            self.controlActionTasks.removeValue(forKey: key)
        }
        controlActionTasks[key] = task
        return task
    }

    func cancelControlActions() -> [Task<Void, Never>] {
        let currentToken = SimulatorControlActionTaskContext.token
        let cancelledKeys = controlActionTaskTokens.compactMap { key, token in
            token == currentToken ? nil : key
        }
        let tasks = cancelledKeys.compactMap { controlActionTasks.removeValue(forKey: $0) }
        for key in cancelledKeys {
            controlActionTaskTokens.removeValue(forKey: key)
        }
        tasks.forEach { $0.cancel() }
        return tasks
    }

    /// Whether the current worker negotiated a capability.
    /// - Parameter capability: The capability to test.
    /// - Returns: `true` when the worker advertised support.
    public func supports(_ capability: SimulatorCapability) -> Bool {
        capabilities.contains(capability)
    }

    /// Executes one typed public Simulator control action and updates matching
    /// inspector state.
    /// - Parameter action: The action to execute for a concrete device.
    /// - Returns: The typed result returned by the control client.
    @discardableResult
    public func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let generation = selectionGeneration
        activeControlActions += 1
        isPerformingControlAction = true
        defer {
            activeControlActions -= 1
            isPerformingControlAction = activeControlActions > 0
        }
        do {
            let result = try await client.perform(action)
            // A returned result is the external commit boundary. Cancellation
            // after it suppresses stale presentation work, not the success.
            guard !Task.isCancelled else { return result }
            guard generation == selectionGeneration, !closed else { return result }
            controlFailure = nil
            apply(result, for: action)
            appendCoordinatorAction(for: action, succeeded: true)
            return result
        } catch {
            guard generation == selectionGeneration, !closed else { throw error }
            let failure = simulatorPaneFailure(from: error, code: "control_action_failed")
            controlFailure = failure
            appendCoordinatorAction(for: action, succeeded: false)
            throw failure
        }
    }

    /// Refreshes the installed application list.
    public func refreshApplications() async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.listApplications(deviceID: deviceID))
    }

    /// Presents a native picker and installs the selected app or IPA.
    public func installApplication() async {
        guard let deviceID = selectedDeviceID,
              let url = await filePicker.chooseApplication() else { return }
        do {
            try await perform(.installApplication(deviceID: deviceID, applicationURL: url))
            await refreshApplications()
        } catch {}
    }

    /// Launches one installed application with optional native launch options.
    /// - Parameters:
    ///   - bundleIdentifier: The installed bundle identifier.
    ///   - configuration: Arguments, environment, and debugger options.
    public func launchApplication(
        bundleIdentifier: String,
        configuration: SimulatorLaunchConfiguration = SimulatorLaunchConfiguration()
    ) async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.launchApplication(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier,
            configuration: configuration
        ))
    }

    /// Terminates one installed application.
    /// - Parameter bundleIdentifier: The installed bundle identifier.
    public func terminateApplication(bundleIdentifier: String) async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.terminateApplication(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier
        ))
    }

    /// Opens a URL in the simulated operating system.
    /// - Parameter value: An absolute URL string.
    public func openURL(_ value: String) async {
        guard let deviceID = selectedDeviceID, let url = URL(string: value) else { return }
        _ = try? await perform(.openURL(deviceID: deviceID, url: url))
    }

    /// Presents a native picker and imports the selected media.
    public func addMedia() async {
        guard let deviceID = selectedDeviceID else { return }
        let urls = await filePicker.chooseMedia()
        guard !urls.isEmpty else { return }
        _ = try? await perform(.addMedia(deviceID: deviceID, urls: urls))
    }

    /// Routes dropped app bundles, IPA archives, and media through native
    /// Simulator controls.
    /// - Parameter urls: File URLs dropped on the live device stage.
    public func importDroppedFiles(_ urls: [URL]) async {
        guard canImportDroppedFiles(urls), let deviceID = selectedDeviceID else { return }
        let applications = urls.filter {
            let extensionName = $0.pathExtension.lowercased()
            return extensionName == "app" || extensionName == "ipa"
        }
        let media = urls.filter {
            simulatorDroppedMediaExtensions.contains($0.pathExtension.lowercased())
        }
        var installedApplication = false
        var installFailure: SimulatorFailure?
        for application in applications {
            do {
                try await perform(.installApplication(
                    deviceID: deviceID,
                    applicationURL: application
                ))
                installedApplication = true
            } catch let failure as SimulatorFailure {
                installFailure = failure
            } catch {}
        }
        if !media.isEmpty {
            _ = try? await perform(.addMedia(deviceID: deviceID, urls: media))
        }
        if installedApplication {
            await refreshApplications()
        }
        if let installFailure { controlFailure = installFailure }
    }

    /// Returns whether this pane can accept at least one dropped application or media file.
    public func canImportDroppedFiles(_ urls: [URL]) -> Bool {
        guard selectedDeviceID != nil else { return false }
        return urls.contains { url in
            let extensionName = url.pathExtension.lowercased()
            return extensionName == "app"
                || extensionName == "ipa"
                || simulatorDroppedMediaExtensions.contains(extensionName)
        }
    }

    /// Reads plain text from the simulated pasteboard.
    public func readClipboard() async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.readClipboard(deviceID: deviceID))
    }

    /// Writes plain text to the simulated pasteboard.
    /// - Parameter text: The replacement pasteboard text.
    public func writeClipboard(_ text: String) async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.writeClipboard(deviceID: deviceID, text: text))
    }

    /// Copies the host pasteboard into the simulated pasteboard.
    public func syncClipboardFromHost() async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.syncClipboardFromHost(deviceID: deviceID))
    }

    /// Presents a native JSON picker and sends a push notification.
    /// - Parameter bundleIdentifier: The target app's bundle identifier.
    public func pushNotification(bundleIdentifier: String) async {
        guard let deviceID = selectedDeviceID,
              let payloadURL = await filePicker.choosePushPayload() else { return }
        _ = try? await perform(.pushNotification(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier,
            payloadURL: payloadURL
        ))
    }

    /// Applies one privacy-database action.
    public func setPrivacy(
        _ action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundleIdentifier: String?
    ) async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.setPrivacy(
            deviceID: deviceID,
            action: action,
            service: service,
            bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
        ))
    }

    /// Reads effective permission values for an app or the entire runtime.
    /// - Parameter bundleIdentifier: The optional target bundle identifier.
    public func readPrivacy(bundleIdentifier: String?) async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.readPrivacy(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
        ))
    }

    /// Applies a partial status bar override.
    /// - Parameter values: The values to merge into the status bar.
    public func overrideStatusBar(_ values: SimulatorStatusBarOverride) async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.overrideStatusBar(deviceID: deviceID, values: values))
    }

    /// Clears all status bar overrides.
    public func clearStatusBar() async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.clearStatusBar(deviceID: deviceID))
    }

    /// Applies a supported appearance or accessibility setting.
    /// - Parameter setting: The public `simctl ui` setting.
    public func setInterface(_ setting: SimulatorInterfaceSetting) async {
        guard let deviceID = selectedDeviceID else { return }
        guard (try? await perform(.setInterface(deviceID: deviceID, setting: setting))) != nil else { return }
        await refreshInterfaceStatus()
    }

    /// Toggles light and dark appearance using a fresh Simulator readback when needed.
    public func toggleAppearance() async {
        if interfaceStatus?.appearance == nil { await refreshInterfaceStatus() }
        let next: SimulatorInterfaceSetting.Appearance = interfaceStatus?.appearance == .dark
            ? .light
            : .dark
        await setInterface(.appearance(next))
    }

    /// Reads live private appearance and accessibility values.
    public func refreshInterfaceStatus() async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.readInterfaceStatus(deviceID: deviceID))
    }

    /// Presents a native save panel and captures a screenshot.
    /// - Parameter format: The desired screenshot format.
    public func captureScreenshot(format: SimulatorScreenshotFormat) async {
        guard let deviceID = selectedDeviceID,
              let destination = await filePicker.chooseScreenshotDestination(
                  fileExtension: format.rawValue
              ) else { return }
        _ = try? await perform(.screenshot(
            deviceID: deviceID,
            destinationURL: destination,
            format: format
        ))
    }

    /// Starts or stops a cancellable Simulator video recording.
    /// - Parameter codec: The recording codec to use when starting.
    public func toggleVideoRecording(codec: SimulatorVideoCodec) async {
        if let videoSession {
            await videoSession.stopAndWait()
            self.videoSession = nil
            isVideoRecording = false
            return
        }
        guard let deviceID = selectedDeviceID,
              let destination = await filePicker.chooseVideoDestination(),
              case let .command(descriptor) = try? await perform(.prepareVideoRecording(
                  deviceID: deviceID,
                  destinationURL: destination,
                  codec: codec
              )) else { return }
        let session = SimulatorProcessSession()
        do {
            try session.start(descriptor, capturesOutput: false, onOutput: { _ in }) { [weak self] in
                self?.videoSession = nil
                self?.isVideoRecording = false
            }
            videoSession = session
            isVideoRecording = true
        } catch {
            controlFailure = simulatorPaneFailure(from: error, code: "video_recording_failed")
        }
    }

    /// Reads a bounded interval from the simulated unified log.
    public func loadRecentLogs(bundleIdentifier: String?, seconds: Double = 60) async {
        guard let deviceID = selectedDeviceID else { return }
        _ = try? await perform(.recentLogs(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil,
            seconds: seconds
        ))
    }

    /// Starts or stops a cancellable live Simulator unified-log stream.
    public func toggleLogStream(bundleIdentifier: String?) async {
        if let logSession {
            await logSession.stopAndWait()
            self.logSession = nil
            isStreamingLogs = false
            return
        }
        guard let deviceID = selectedDeviceID,
              case let .command(descriptor) = try? await perform(.prepareLogStream(
                  deviceID: deviceID,
                  bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
              )) else { return }
        liveLogsText = ""
        await liveLogBuffer.reset()
        let session = SimulatorProcessSession()
        let liveLogBuffer = liveLogBuffer
        do {
            try session.start(descriptor, capturesOutput: true) { [weak self] line in
                guard let snapshot = await liveLogBuffer.append(line) else { return }
                await MainActor.run { [weak self] in self?.liveLogsText = snapshot }
            } onTermination: { [weak self] in
                guard let self else { return }
                self.logSession = nil
                self.isStreamingLogs = false
                let buffer = self.liveLogBuffer
                Task { @MainActor [weak self] in
                    self?.liveLogsText = await buffer.snapshot()
                }
            }
            logSession = session
            isStreamingLogs = true
        } catch {
            controlFailure = simulatorPaneFailure(from: error, code: "log_stream_failed")
        }
    }

    private func apply(_ result: SimulatorControlResult, for action: SimulatorControlAction) {
        switch result {
        case .none, .processIdentifier, .command:
            break
        case let .applications(applications):
            installedApplications = applications.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            userInstalledApplications = installedApplications.filter {
                $0.applicationType.caseInsensitiveCompare("User") == .orderedSame
            }
        case let .text(text):
            switch action {
            case .readClipboard:
                clipboardText = text
            case .recentLogs:
                recentLogsText = text
            default:
                break
            }
        case let .privacy(snapshot):
            privacySnapshot = snapshot
        case let .cameraStatus(status):
            cameraStatus = status
            cameraConfiguration = status.configuration
        case let .interfaceStatus(status):
            interfaceStatus = status
        case let .accessibility(snapshot):
            applyAccessibilitySnapshot(snapshot)
        case let .foregroundApplication(application):
            foregroundApplication = application
        case let .webInspectorTargets(targets):
            webInspectorTargets = targets
        case let .webInspectorSession(status):
            applyWebInspectorSession(status)
        }
    }

    private func appendCoordinatorAction(
        for action: SimulatorControlAction,
        succeeded: Bool
    ) {
        guard let name = simulatorCoordinatorActionName(action) else { return }
        actionLog.insert(SimulatorActionLogEntry(
            id: UUID(),
            timestamp: Date(),
            action: name,
            summary: name,
            succeeded: succeeded
        ), at: 0)
        if actionLog.count > Self.maximumActionLogCount {
            actionLog.removeLast(actionLog.count - Self.maximumActionLogCount)
        }
    }

}

private func simulatorCoordinatorActionName(_ action: SimulatorControlAction) -> String? {
    switch action {
    case .interactive:
        nil
    case .listApplications, .installApplication, .launchApplication,
         .terminateApplication, .cleanupCameraApplication:
        "applications"
    case .openURL:
        "open_url"
    case .addMedia:
        "media"
    case .readClipboard, .writeClipboard, .syncClipboardFromHost:
        "clipboard"
    case .setLocation, .clearLocation, .startLocationRoute,
         .pauseLocationRoute, .resumeLocationRoute, .stopLocationRoute:
        "location"
    case .pushNotification:
        "push_notification"
    case .overrideStatusBar, .clearStatusBar:
        "status_bar"
    case .setInterface:
        "interface"
    case .screenshot, .prepareVideoRecording:
        "capture"
    case .recentLogs, .prepareLogStream:
        "logs"
    case .setPrivacy, .readPrivacy, .readInterfaceStatus, .configureCamera, .switchCameraSource, .setCameraMirror,
         .readCameraStatus, .reloadReactNative, .readAccessibility,
         .readForegroundApplication, .setAccessibilityHighlight,
         .refreshWebInspectorTargets, .attachWebInspector, .releaseWebInspector,
         .setWebInspectorHighlight, .sendWebInspectorMessage:
        nil
    }
}
