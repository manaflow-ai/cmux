import CmuxSentryReporting
import Foundation
import Sentry

@MainActor private var sentryMemoryContextRefreshTask: Task<Void, Never>?
@MainActor private var sentryLastMemoryContextRefresh: Date?

/// Add a Sentry breadcrumb for user-action context in hang/crash reports.
func sentryBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {
    guard SentrySDK.isEnabled else { return }
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
    guard SentrySDK.isEnabled else { return }
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
    guard SentrySDK.isEnabled else { return }
    sentryScheduleMemoryContextRefresh(reason: "startup", minimumInterval: 0)
}

@MainActor
func sentryStopMemoryContextRefresh() {
    sentryMemoryContextRefreshTask?.cancel()
    sentryMemoryContextRefreshTask = nil
    sentryLastMemoryContextRefresh = nil
}

private func sentryRequestMemoryContextRefresh(reason: String) {
    guard SentrySDK.isEnabled else { return }
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
#if compiler(>=6.2)
@concurrent
#else
@Sendable
#endif
nonisolated func sentryRefreshMemoryContext(reason: String) async {
    guard SentrySDK.isEnabled else { return }

    let processSnapshot = CmuxTopProcessSnapshot.captureCached(
        includeProcessDetails: false,
        maximumAge: 2
    )
    let sample = MemoryResourceSample(processSnapshot: processSnapshot)
    guard !Task.isCancelled else { return }

    await MainActor.run {
        guard !Task.isCancelled else { return }
        var payload = sample.payload(
            views: MemoryResourceViewCounts.capture(),
            monitor: MemoryPressureMonitor.shared.resourceDiagnosticPayload()
        )
        payload["reason"] = reason
        SentrySDK.configureScope { scope in
            scope.setContext(value: payload, key: "cmux.memory")
        }
    }
}
