#if os(iOS)
import CmuxDeviceHub
import CmuxMobileComputerUse
import CmuxMobileLive
import CmuxMobileNotifications
import CmuxMobileScreenSharing
import Foundation
import OSLog
import UIKit
import UserNotifications

private let log = Logger(subsystem: "dev.cmux.mobile", category: "computer-use")

/// Connects ``ComputerUseApprovals`` to the app: the device hub (the Screen Sharing
/// service's, or a client built for a cold background launch), the Mac links and
/// mailbox for a Mac's questions, Face ID, the app's lock and Notification Center.
@MainActor
final class ComputerUseHost {
    static let shared = ComputerUseHost()

    /// A client built while no hub runs (a lock-screen Deny on a cold launch).
    private var coldClient: DeviceHubClient?

    /// The hub this build uses: DEBUG builds the dev hub, every other build production.
    let hubURL: URL

    private init() {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        hubURL = ScreenSharingService.hubURL(isDebug: isDebug, environment: ProcessInfo.processInfo.environment)
    }

    /// At launch, before any notification can arrive.
    func configure() {
        let host = self
        ComputerUseApprovals.shared.environment = ComputerUseApprovals.Environment(
            hubURL: hubURL,
            client: { await host.client() },
            answerMac: { try await host.answerMac($0) },
            isInteractive: { UIApplication.shared.applicationState == .active && !NotificationRouter.shared.appLocked },
            removeNotification: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [$0]) },
            pushTopic: Bundle.main.bundleIdentifier,
            pushEnvironment: PushRegistration.environment == "production" ? .production : .development
        )
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ComputerUseApprovals.shared.interactivityChanged() }
        }
    }

    /// Follows the account's hub once Screen Sharing loaded and registered this phone.
    func attach(_ service: ScreenSharingService) {
        service.onHubReady = { hub in ComputerUseApprovals.shared.follow(hub) }
        coldClient = nil
        service.start()
    }

    /// Signed out.
    func detach() {
        ComputerUseApprovals.shared.unfollow()
        coldClient = nil
    }

    /// A client signed in as this phone.
    func client() async -> DeviceHubClient? {
        if let hub = ScreenSharingService.current?.hub { return hub.client }
        if let coldClient { return coldClient }
        guard let auth = PushReplies.shared.auth, !auth.isMock else { return nil }
        _ = await ObservationWait({ auth.isResolved }, budget: .seconds(3)).value
        guard auth.isSignedIn else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "dev.cmux.mobile"
        let identity: CmuxDeviceHub.DeviceIdentity
        do {
            identity = try await Task.detached(priority: .userInitiated) { try CmuxDeviceHub.DeviceIdentity.forApp(bundleIdentifier: bundle) }.value
        } catch {
            log.error("computer use: this phone's device identity did not load: \(String(describing: error), privacy: .public)")
            return nil
        }
        let client = DeviceHubClient(baseURL: hubURL, identity: identity, tokens: DeviceHubAccountToken { try await auth.accessToken() })
        coldClient = client
        return client
    }

    /// A Mac's question answered: signed (an Allow, after Face ID), then over that Mac's
    /// link, else through the reply mailbox.
    func answerMac(_ answer: ComputerUseMacAnswer) async throws {
        do {
            try await PushReplies.shared.onCoordinator { live in
                let signed = try await live.signComputerUseAnswer(mac: answer.macID, macName: answer.macName, digest: answer.digest,
                                                                  decision: answer.decision.rawValue, reason: answer.reason)
                do {
                    try await live.deliverComputerUseAnswer(signed)
                } catch let failure as LiveCoordinator.PushReplyFailure where failure.reason == .unreachable {
                    _ = try await live.deliverComputerUseAnswerViaMailbox(signed)
                }
            }
        } catch let failure as LiveCoordinator.PushReplyFailure {
            switch failure.reason {
            case .cancelled: throw ComputerUseMacAnswer.Failure.cancelled
            case let .refused(message): throw ComputerUseMacAnswer.Failure.refused(message)
            case .unreachable: throw ComputerUseMacAnswer.Failure.unreachable
            }
        } catch {
            log.error("computer use answer to the Mac failed: \(String(describing: error), privacy: .public)")
            throw ComputerUseMacAnswer.Failure.unreachable
        }
        // The question's notification (eventId `cu-` + the digest's first 32 hex digits) leaves Notification Center.
        PushReplies.shared.clearDelivered(eventId: "cu-" + answer.digest.prefix(32))
    }
}
#endif
