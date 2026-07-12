internal import CMUXMobileCore
internal import Foundation

// Safety: NotificationCenter owns the callback concurrently, while this type's
// stored token and center are immutable after initialization. The callback only
// synchronizes injected thread-safe consent/uploader seams and yields into a
// thread-safe AsyncStream.
final class AnalyticsConsentRevocationObserver: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let token: any NSObjectProtocol

    init(
        notificationCenter: NotificationCenter,
        consent: any AnalyticsConsentProviding,
        uploader: any AnalyticsUploading,
        generationGate: AnalyticsConsentGenerationGate,
        onConsentChange: @escaping @Sendable (AnalyticsConsentSnapshot) -> Void
    ) {
        self.notificationCenter = notificationCenter
        uploader.setUploadsEnabled(consent.isTelemetryEnabled)
        self.token = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            let base = generationGate.snapshot()
            let observedEnabled = consent.isTelemetryEnabled
            _ = generationGate.synchronize(
                observedEnabled: observedEnabled,
                basedOn: base
            ) { snapshot in
                // Publish transport state before the FIFO command. A capture
                // racing notification delivery therefore cannot be accepted by
                // consent and then dropped by a still-disabled uploader.
                uploader.setUploadsEnabled(snapshot.isEnabled)
                onConsentChange(snapshot)
            }
        }
    }

    deinit {
        notificationCenter.removeObserver(token)
    }
}
