import Foundation

/// Owns the legacy notification seam for the registry's network recovery refresh.
@MainActor
final class CloudReadRecoveryObserver {
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter, recover: @escaping @MainActor @Sendable () async -> Void) {
        self.notificationCenter = notificationCenter
        observer = notificationCenter.addObserver(forName: .cmuxCloudReadNetworkRecovered, object: nil, queue: .main) { _ in
            Task { @MainActor in await recover() }
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }
}
