internal import CMUXMobileCore
internal import Foundation

// Safety: NotificationCenter owns the callback concurrently, while this type's
// stored token and center are immutable after initialization. The callback only
// reads injected Sendable seams and yields into a thread-safe AsyncStream.
final class AnalyticsConsentRevocationObserver: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let token: any NSObjectProtocol

    init(
        notificationCenter: NotificationCenter,
        consent: any AnalyticsConsentProviding,
        uploader: any AnalyticsUploading,
        onConsentChange: @escaping @Sendable (Bool) -> Void
    ) {
        self.notificationCenter = notificationCenter
        uploader.setUploadsEnabled(consent.isTelemetryEnabled)
        self.token = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            let isEnabled = consent.isTelemetryEnabled
            if !isEnabled { uploader.setUploadsEnabled(false) }
            onConsentChange(isEnabled)
        }
    }

    deinit {
        notificationCenter.removeObserver(token)
    }
}
