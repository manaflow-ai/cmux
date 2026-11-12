#if DEBUG
import AppKit

/// Writes the opt-in diagnostics manifest consumed by UI-test harnesses.
///
/// The application supplies the two pieces of app state that are specific to
/// AppDelegate (socket health and the focused terminal render state); all file
/// and AppKit diagnostics formatting stays here.
@MainActor
final class UITestDiagnosticsWriter {
    struct RenderDiagnostics {
        let panelId: UUID
        let drawCount: Int
        let presentCount: Int
        let lastPresentTime: Double
        let windowVisible: Bool
        let appIsActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    private let isRunningUnderXCTest: ([String: String]) -> Bool
    private let socketDiagnostics: ([String: String]) -> [String: String]
    private let renderDiagnostics: () -> RenderDiagnostics?

    init(
        isRunningUnderXCTest: @escaping ([String: String]) -> Bool,
        socketDiagnostics: @escaping ([String: String]) -> [String: String],
        renderDiagnostics: @escaping () -> RenderDiagnostics?
    ) {
        self.isRunningUnderXCTest = isRunningUnderXCTest
        self.socketDiagnostics = socketDiagnostics
        self.renderDiagnostics = renderDiagnostics
    }

    func write(stage: String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

        var payload = load(at: path)
        let windows = NSApp.windows
        let targetDisplayID = env["CMUX_UI_TEST_TARGET_DISPLAY_ID"] ?? ""
        payload["stage"] = stage
        payload["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        payload["bundleId"] = Bundle.main.bundleIdentifier ?? ""
        payload["isRunningUnderXCTest"] = isRunningUnderXCTest(env) ? "1" : "0"
        payload["windowsCount"] = String(windows.count)
        payload["windowIdentifiers"] = windows.map { $0.identifier?.rawValue ?? "" }.joined(separator: ",")
        payload["windowVisibleFlags"] = windows.map { $0.isVisible ? "1" : "0" }.joined(separator: ",")
        payload["windowScreenDisplayIDs"] = windows.map { $0.screen?.cmuxDisplayID.map(String.init) ?? "" }.joined(separator: ",")
        payload["uiTestTargetDisplayID"] = targetDisplayID
        if let rawDisplayID = UInt32(targetDisplayID) {
            payload["targetDisplayPresent"] = NSScreen.screens.contains { $0.cmuxDisplayID == rawDisplayID } ? "1" : "0"
            payload["targetDisplayMoveSucceeded"] = windows.contains { $0.screen?.cmuxDisplayID == rawDisplayID } ? "1" : "0"
        }
        appendRenderDiagnostics(to: &payload, environment: env)
        payload.merge(socketDiagnostics(env)) { _, new in new }
        appendPortalDiagnostics(to: &payload, environment: env)

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func load(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func appendPortalDiagnostics(to payload: inout [String: String], environment env: [String: String]) {
        guard env["CMUX_UI_TEST_PORTAL_STATS"] == "1" else { return }
        let stats = TerminalWindowPortalRegistry.debugPortalStats()
        payload["portal_count"] = stringValue(stats["portal_count"])
        payload["portal_hosted_mapping_count"] = stringValue(stats["hosted_mapping_count"])
        payload["portal_guarded_bind_blocked_count"] = stringValue(stats["guarded_bind_blocked_count"])
        if let totals = stats["totals"] as? [String: Any] {
            for (key, value) in totals { payload["portal_\(key)"] = stringValue(value) }
        }
    }

    private func appendRenderDiagnostics(to payload: inout [String: String], environment env: [String: String]) {
        guard env["CMUX_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return }
        guard let state = renderDiagnostics() else {
            payload["renderStatsAvailable"] = "0"
            for key in ["renderPanelId", "renderDrawCount", "renderPresentCount", "renderLastPresentTime", "renderWindowVisible", "renderAppIsActive", "renderDesiredFocus", "renderIsFirstResponder"] { payload[key] = "" }
            payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
            return
        }
        payload["renderStatsAvailable"] = "1"
        payload["renderPanelId"] = state.panelId.uuidString
        payload["renderDrawCount"] = String(state.drawCount)
        payload["renderPresentCount"] = String(state.presentCount)
        payload["renderLastPresentTime"] = String(format: "%.6f", state.lastPresentTime)
        payload["renderWindowVisible"] = state.windowVisible ? "1" : "0"
        payload["renderAppIsActive"] = state.appIsActive ? "1" : "0"
        payload["renderDesiredFocus"] = state.desiredFocus ? "1" : "0"
        payload["renderIsFirstResponder"] = state.isFirstResponder ? "1" : "0"
        payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
    }

    private func stringValue(_ value: Any?) -> String {
        switch value {
        case let value as String: return value
        case let value as Bool: return value ? "1" : "0"
        case let value as Int: return String(value)
        case let value as NSNumber: return value.stringValue
        case let value as UUID: return value.uuidString
        case .some(let value): return String(describing: value)
        case .none: return ""
        }
    }
}
#endif
