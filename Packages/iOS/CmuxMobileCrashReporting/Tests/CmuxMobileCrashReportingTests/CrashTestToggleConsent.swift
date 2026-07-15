import Foundation

import CmuxMobileAnalytics

final class CrashTestToggleConsent: AnalyticsConsentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEnabled: Bool

    init(enabled: Bool) {
        self.storedEnabled = enabled
    }

    var enabled: Bool {
        get { lock.withLock { storedEnabled } }
        set { lock.withLock { storedEnabled = newValue } }
    }

    var isTelemetryEnabled: Bool { enabled }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }
}
