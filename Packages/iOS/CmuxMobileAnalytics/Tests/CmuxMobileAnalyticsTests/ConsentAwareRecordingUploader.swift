import os

@testable import CmuxMobileAnalytics

final class ConsentAwareRecordingUploader: AnalyticsUploading, Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (isEnabled: true, uploadedEvents: [AnalyticsEvent]())
    )

    var uploadedEvents: [AnalyticsEvent] {
        state.withLock { $0.uploadedEvents }
    }

    func setUploadsEnabled(_ isEnabled: Bool) {
        state.withLock { $0.isEnabled = isEnabled }
    }

    func upload(_ events: [AnalyticsEvent]) async -> AnalyticsUploadResult {
        state.withLock { state in
            guard state.isEnabled else { return .drop }
            state.uploadedEvents.append(contentsOf: events)
            return .accepted
        }
    }

    func identify(
        userID _: String?,
        anonymousID _: String?,
        properties _: [String: any Sendable]
    ) async -> AnalyticsUploadResult {
        state.withLock { $0.isEnabled ? .accepted : .drop }
    }
}
