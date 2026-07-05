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

    func startCuaDriver() async {
        await CuaDriverManager.shared.start(settingValue: computerUseDriverPath())
    }

    func stopCuaDriver() async {
        await CuaDriverManager.shared.stop()
    }

    func requestAccessibilityAccess() async {
        _ = computerUsePermissionChecker.requestAccessibility()
    }

    func requestScreenRecordingAccess() async {
        screenRecordingRequested = true
        _ = computerUsePermissionChecker.requestScreenRecording()
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
