import Darwin
import Foundation
import Sentry

/// Add a Sentry breadcrumb for user-action context in hang/crash reports.
func sentryBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }
    let crumb = Breadcrumb(level: .info, category: category)
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
}

private func sentryCaptureMessage(
    _ message: String,
    level: SentryLevel,
    category: String,
    data: [String: Any]?,
    contextKey: String?
) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }
    _ = SentrySDK.capture(message: message) { scope in
        scope.setLevel(level)
        scope.setTag(value: category, key: "category")
        if let data {
            scope.setContext(value: data, key: contextKey ?? category)
        }
    }
}

func sentryCaptureWarning(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {
    sentryCaptureMessage(message, level: .warning, category: category, data: data, contextKey: contextKey)
}

func sentryCaptureError(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {
    sentryCaptureMessage(message, level: .error, category: category, data: data, contextKey: contextKey)
}

/// Refresh the memory/surface context attached to future Sentry events.
@MainActor
func sentryRefreshMemoryContext(reason: String) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }

    let processSnapshot = CmuxTopProcessSnapshot.captureCached(
        includeProcessDetails: false,
        maximumAge: 2
    )
    let appProcess = processSnapshot.process(pid: Int(Darwin.getpid()))
    SentrySDK.configureScope { scope in
        scope.setContext(value: [
            "reason": reason,
            "sampled_at": ISO8601DateFormatter().string(from: processSnapshot.sampledAt),
            "app": [
                "pid": Int(Darwin.getpid()),
                "physical_footprint_bytes": appProcess?.memoryBytes ?? 0,
                "resident_bytes": appProcess?.residentBytes ?? 0,
                "virtual_bytes": appProcess?.virtualBytes ?? 0,
                "thread_count": appProcess?.threadCount ?? 0,
                "memory_source": appProcess?.memorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue,
                "resident_memory_source": appProcess?.residentMemorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue
            ],
            "terminal_surfaces": GhosttyApp.terminalSurfaceRegistry.diagnosticSnapshot().payload()
        ], key: "cmux.memory")
    }
}
