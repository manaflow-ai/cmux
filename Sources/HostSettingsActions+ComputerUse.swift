import AppKit
import CmuxSettings
import CmuxSettingsUI
import Foundation

extension HostSettingsActions {
    func computerUseState() async -> ComputerUseHostState {
        let driverPath = computerUseDriverPath()
        let manager = CuaDriverManager.shared
        let resolved = manager.resolve(settingValue: driverPath)
        let triedSources = manager.resolutionCandidates(settingValue: driverPath)
            .map { computerUseDriverSource($0.source) }

        return ComputerUseHostState(
            driverState: computerUseDriverState(manager.state, resolved: resolved),
            resolvedDriver: resolved.map {
                ComputerUseHostState.ResolvedDriver(
                    path: $0.url.path,
                    source: computerUseDriverSource($0.source)
                )
            },
            triedSources: triedSources,
            accessibilityGranted: computerUsePermissionChecker.accessibilityGranted,
            screenRecordingGranted: computerUsePermissionChecker.screenRecordingGranted,
            screenRecordingRequested: screenRecordingRequested
        )
    }

    func computerUseDriverStateUpdates() -> AsyncStream<ComputerUseHostState.DriverState> {
        let updates = CuaDriverManager.shared.stateUpdates()
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await state in updates {
                    let resolved = CuaDriverManager.shared.resolve(settingValue: computerUseDriverPath())
                    continuation.yield(computerUseDriverState(state, resolved: resolved))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func ensureCuaDriver() async {
        _ = await CuaDriverManager.shared.ensure(settingValue: computerUseDriverPath())
    }

    func requestAccessibilityAccess() async -> Bool {
        computerUsePermissionChecker.requestAccessibility()
    }

    func requestScreenRecordingAccess() async -> Bool {
        screenRecordingRequested = true
        return computerUsePermissionChecker.requestScreenRecording()
    }

    func openPrivacyPane(anchor: ComputerUsePrivacyPaneAnchor) {
        let fragment: String
        switch anchor {
        case .accessibility:
            fragment = "Privacy_Accessibility"
        case .screenRecording:
            fragment = "Privacy_ScreenCapture"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(fragment)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func computerUseDriverPath() -> String {
        computerUseConfigStore.snapshotValue(for: SettingCatalog().computerUse.driverPath)
    }

    private func computerUseDriverState(
        _ state: CuaDriverManager.State,
        resolved: CuaDriverBinaryResolution?
    ) -> ComputerUseHostState.DriverState {
        if resolved == nil {
            switch state {
            case .starting, .running, .failed:
                break
            case .notFound, .stopped:
                return .notFound
            }
        } else if case .notFound = state {
            return .stopped
        }

        switch state {
        case .notFound:
            return .notFound
        case .stopped:
            return .stopped
        case .starting:
            return .starting
        case .running(let info):
            return .running(
                pid: info.pid,
                serverName: info.serverName,
                serverVersion: info.serverVersion,
                toolCount: info.toolCount
            )
        case .failed(let message):
            return .failed(message)
        }
    }

    private func computerUseDriverSource(_ source: CuaDriverBinaryResolution.Source) -> ComputerUseDriverSource {
        ComputerUseDriverSource(rawValue: source.rawValue) ?? .setting
    }
}

extension TerminalController {
    nonisolated func v2CuaMainActorResultCall(
        id: Any?,
        timeoutSeconds: TimeInterval,
        _ work: @escaping @MainActor () async -> V2CallResult
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: V2CallResult?
        // Issue #4602 can saturate the cooperative pool during session-index scans;
        // the main executor remains responsive and these CUA operations are main-actor isolated.
        let task = Task { @MainActor in
            result = await work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "Request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
        guard let result else {
            return v2Error(
                id: id,
                code: "request_error",
                message: "Request failed before returning a result"
            )
        }
        return v2Result(id: id, result)
    }

    nonisolated func v2CuaSocketWorkerResponse(method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "cua.status":
            return v2CuaMainActorResultCall(id: id, timeoutSeconds: 30) { await self.v2CuaStatusResult() }
        case "cua.ensure":
            return v2CuaMainActorResultCall(id: id, timeoutSeconds: 30) { await self.v2CuaEnsureResult() }
        case "cua.grant":
            return v2CuaMainActorResultCall(id: id, timeoutSeconds: 30) { await self.v2CuaGrantResult(params: params) }
        case "cua.openSystemSettings":
            return v2CuaMainActorResultCall(id: id, timeoutSeconds: 30) {
                self.v2CuaOpenSystemSettingsResult(params: params)
            }
        default:
            preconditionFailure("Unsupported Computer Use socket method")
        }
    }

    func v2CuaStatusResult() async -> V2CallResult {
        guard let hostActions = AppDelegate.shared?.settingsRuntime?.hostActions else {
            return .err(code: "unavailable", message: "Computer Use settings are unavailable", data: nil)
        }
        return .ok(computerUseSocketPayload(await hostActions.computerUseState()))
    }

    func v2CuaEnsureResult() async -> V2CallResult {
        guard let hostActions = AppDelegate.shared?.settingsRuntime?.hostActions else {
            return .err(code: "unavailable", message: "Computer Use settings are unavailable", data: nil)
        }
        await hostActions.ensureCuaDriver()
        return .ok(computerUseSocketPayload(await hostActions.computerUseState()))
    }

    func v2CuaGrantResult(params: [String: Any]) async -> V2CallResult {
        guard let permission = computerUsePermission(from: params) else {
            return .err(
                code: "invalid_params",
                message: "permission must be accessibility or screenRecording",
                data: nil
            )
        }
        guard let hostActions = AppDelegate.shared?.settingsRuntime?.hostActions else {
            return .err(code: "unavailable", message: "Computer Use settings are unavailable", data: nil)
        }

        let granted: Bool
        switch permission {
        case .accessibility:
            granted = await hostActions.requestAccessibilityAccess()
        case .screenRecording:
            granted = await hostActions.requestScreenRecordingAccess()
        }
        return .ok([
            "granted": granted,
            "prompted": true,
        ])
    }

    func v2CuaOpenSystemSettingsResult(params: [String: Any]) -> V2CallResult {
        guard let permission = computerUsePermission(from: params) else {
            return .err(
                code: "invalid_params",
                message: "permission must be accessibility or screenRecording",
                data: nil
            )
        }
        guard let hostActions = AppDelegate.shared?.settingsRuntime?.hostActions else {
            return .err(code: "unavailable", message: "Computer Use settings are unavailable", data: nil)
        }
        hostActions.openPrivacyPane(anchor: permission)
        return .ok([
            "opened": true,
            "permission": permission == .accessibility ? "accessibility" : "screenRecording",
        ])
    }

    private func computerUsePermission(from params: [String: Any]) -> ComputerUsePrivacyPaneAnchor? {
        guard let raw = params["permission"] as? String else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "accessibility":
            return .accessibility
        case "screenRecording":
            return .screenRecording
        default:
            return nil
        }
    }

    private func computerUseSocketPayload(_ state: ComputerUseHostState) -> [String: Any] {
        var driver: [String: Any] = [:]
        switch state.driverState {
        case .notFound:
            driver["state"] = "notFound"
        case .stopped:
            driver["state"] = "idle"
        case .starting:
            driver["state"] = "starting"
        case .running(let pid, let serverName, let serverVersion, let toolCount):
            driver["state"] = "running"
            driver["pid"] = pid
            driver["toolCount"] = toolCount
            if let serverName { driver["serverName"] = serverName }
            if let serverVersion { driver["serverVersion"] = serverVersion }
        case .failed(let reason):
            driver["state"] = "failed"
            driver["failureReason"] = reason
        }
        if let resolved = state.resolvedDriver {
            driver["resolvedPath"] = resolved.path
            driver["resolutionSource"] = resolved.source.rawValue
        }

        return [
            "permissions": [
                "accessibility": state.accessibilityGranted,
                "screenRecording": state.screenRecordingGranted,
            ],
            "driver": driver,
        ]
    }
}
