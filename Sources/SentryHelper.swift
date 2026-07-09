import CMUXAgentLaunch
import Darwin
import CmuxSettings
import CmuxTerminal
import Foundation
import Sentry

@MainActor private var sentryMemoryContextRefreshTask: Task<Void, Never>?
@MainActor private var sentryLastMemoryContextRefresh: Date?

/// Add a Sentry breadcrumb for user-action context in hang/crash reports.
func sentryBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {
    guard telemetrySettings.enabledForCurrentLaunch else { return }
    let crumb = Breadcrumb(level: .info, category: category)
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
    sentryRequestMemoryContextRefresh(reason: "breadcrumb.\(category)")
}

private func sentryCaptureMessage(
    _ message: String,
    level: SentryLevel,
    category: String,
    data: [String: Any]?,
    contextKey: String?
) {
    guard telemetrySettings.enabledForCurrentLaunch else { return }
    _ = SentrySDK.capture(message: message) { scope in
        scope.setLevel(level)
        scope.setTag(value: category, key: "category")
        if let data {
            scope.setContext(value: data, key: contextKey ?? category)
        }
    }
    sentryRequestMemoryContextRefresh(reason: "capture.\(category)")
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

@MainActor
func sentryStartMemoryContextRefresh() {
    guard telemetrySettings.enabledForCurrentLaunch else { return }
    sentryScheduleMemoryContextRefresh(reason: "startup", minimumInterval: 0)
}

@MainActor
func sentryStopMemoryContextRefresh() {
    sentryMemoryContextRefreshTask?.cancel()
    sentryMemoryContextRefreshTask = nil
    sentryLastMemoryContextRefresh = nil
}

private func sentryRequestMemoryContextRefresh(reason: String) {
    guard telemetrySettings.enabledForCurrentLaunch else { return }
    Task { @MainActor in
        sentryScheduleMemoryContextRefresh(reason: reason)
    }
}

@MainActor
private func sentryScheduleMemoryContextRefresh(
    reason: String,
    minimumInterval: TimeInterval = 300
) {
    let now = Date()
    if let sentryLastMemoryContextRefresh,
       now.timeIntervalSince(sentryLastMemoryContextRefresh) < minimumInterval {
        return
    }
    sentryLastMemoryContextRefresh = now
    sentryMemoryContextRefreshTask?.cancel()
    sentryMemoryContextRefreshTask = Task.detached(priority: .utility) {
        await sentryRefreshMemoryContext(reason: reason)
    }
}

/// Refresh the memory/surface context attached to future Sentry events.
func sentryRefreshMemoryContext(reason: String) async {
    guard telemetrySettings.enabledForCurrentLaunch else { return }

    let processSnapshot = CmuxTopProcessSnapshot.captureCached(
        includeProcessDetails: false,
        maximumAge: 2
    )
    let pid = Int(Darwin.getpid())
    let appProcess = processSnapshot.process(pid: pid)
    let sampledAt = ISO8601DateFormatter().string(from: processSnapshot.sampledAt)
    let physicalFootprintBytes = appProcess?.memoryBytes ?? 0
    let residentBytes = appProcess?.residentBytes ?? 0
    let virtualBytes = appProcess?.virtualBytes ?? 0
    let threadCount = appProcess?.threadCount ?? 0
    let memorySource = appProcess?.memorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue
    let residentMemorySource = appProcess?.residentMemorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue
    let surfaceSnapshot = GhosttyApp.terminalSurfaceRegistry.diagnosticSnapshot()
    guard !Task.isCancelled else { return }

    await MainActor.run {
        SentrySDK.configureScope { scope in
            scope.setContext(value: [
                "reason": reason,
                "sampled_at": sampledAt,
                "app": [
                    "pid": pid,
                    "physical_footprint_bytes": physicalFootprintBytes,
                    "resident_bytes": residentBytes,
                    "virtual_bytes": virtualBytes,
                    "thread_count": threadCount,
                    "memory_source": memorySource,
                    "resident_memory_source": residentMemorySource
                ],
                "terminal_surfaces": surfaceSnapshot.payload()
            ], key: "cmux.memory")
        }
    }
}
