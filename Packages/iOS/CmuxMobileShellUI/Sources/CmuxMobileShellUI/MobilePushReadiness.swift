import CmuxAuthRuntime
import CmuxMobileRPC
import Foundation

/// The live iOS notification authorization state used by push readiness.
public enum MobilePushAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unsupported

    fileprivate var permitsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied, .unsupported:
            false
        }
    }
}

/// User-controlled notification presentation switches read live from iOS.
///
/// Authorization can remain `.authorized` while the user independently turns
/// off alerts, sound, badges, Lock Screen, Notification Center, Time Sensitive,
/// or enables Scheduled Delivery. Keeping those controls separate prevents a
/// healthy APNs pipeline from being mislabeled as a fully visible banner path.
public struct MobilePushSystemSettings: Equatable, Sendable {
    public let authorization: MobilePushAuthorization
    public let alertsEnabled: Bool
    public let soundsEnabled: Bool
    public let badgesEnabled: Bool
    public let lockScreenEnabled: Bool
    public let notificationCenterEnabled: Bool
    public let timeSensitiveEnabled: Bool
    public let scheduledDeliveryEnabled: Bool

    public init(
        authorization: MobilePushAuthorization,
        alertsEnabled: Bool,
        soundsEnabled: Bool,
        badgesEnabled: Bool,
        lockScreenEnabled: Bool,
        notificationCenterEnabled: Bool,
        timeSensitiveEnabled: Bool,
        scheduledDeliveryEnabled: Bool
    ) {
        self.authorization = authorization
        self.alertsEnabled = alertsEnabled
        self.soundsEnabled = soundsEnabled
        self.badgesEnabled = badgesEnabled
        self.lockScreenEnabled = lockScreenEnabled
        self.notificationCenterEnabled = notificationCenterEnabled
        self.timeSensitiveEnabled = timeSensitiveEnabled
        self.scheduledDeliveryEnabled = scheduledDeliveryEnabled
    }

    public static func authorizationOnly(
        _ authorization: MobilePushAuthorization
    ) -> Self {
        Self(
            authorization: authorization,
            alertsEnabled: true,
            soundsEnabled: true,
            badgesEnabled: true,
            lockScreenEnabled: true,
            notificationCenterEnabled: true,
            timeSensitiveEnabled: true,
            scheduledDeliveryEnabled: false
        )
    }

    public var presentationLimitations: Set<MobilePushPresentationLimitation> {
        var result: Set<MobilePushPresentationLimitation> = []
        if !alertsEnabled { result.insert(.alertsDisabled) }
        if !soundsEnabled { result.insert(.soundsDisabled) }
        if !badgesEnabled { result.insert(.badgesDisabled) }
        if !lockScreenEnabled { result.insert(.lockScreenDisabled) }
        if !notificationCenterEnabled {
            result.insert(.notificationCenterDisabled)
        }
        if !timeSensitiveEnabled { result.insert(.timeSensitiveDisabled) }
        if scheduledDeliveryEnabled && !timeSensitiveEnabled {
            result.insert(.scheduledDeliveryEnabled)
        }
        return result
    }
}

/// An iOS policy that can make a healthy pipeline quiet, delayed, or partial.
public enum MobilePushPresentationLimitation:
    String,
    CaseIterable,
    Hashable,
    Sendable
{
    case alertsDisabled
    case soundsDisabled
    case badgesDisabled
    case lockScreenDisabled
    case notificationCenterDisabled
    case timeSensitiveDisabled
    case scheduledDeliveryEnabled
}

/// End-to-end readiness for Mac notification delivery on this iOS device.
///
/// A local opt-in is deliberately insufficient. Readiness requires the live OS
/// permission, an APNs token acknowledged by the backend, and authenticated
/// status from the currently attached Mac proving its independent privacy gate,
/// account scope, mode, and API endpoint all agree.
public enum MobilePushReadiness: Equatable, Sendable {
    /// Every gate passed, including the attached Mac's current presence mode.
    case ready(mode: MobileHostPhonePushStatus.Mode)
    /// APNs can deliver, but provisional/ephemeral authorization is quiet or
    /// temporary rather than a fully authorized banner path.
    case limited(
        mode: MobileHostPhonePushStatus.Mode,
        authorization: MobilePushAuthorization
    )
    /// Every transport gate passed, but one or more independent iOS
    /// presentation policies can make delivery quiet, delayed, or invisible.
    case presentationLimited(
        mode: MobileHostPhonePushStatus.Mode,
        limitations: Set<MobilePushPresentationLimitation>
    )
    /// The live path is eligible, but the Mac cannot currently prove that its
    /// bounded retry queue will survive a process restart.
    case reliabilityLimited(
        mode: MobileHostPhonePushStatus.Mode,
        queuePersistence: MobileHostPhonePushStatus.QueuePersistence
    )
    /// Delivery stopped at the named gate.
    case blocked(Blocker)

    /// Authenticated readiness fields read from the attached Mac.
    public struct MacStatus: Equatable, Sendable {
        public let forwardingEnabled: Bool
        public let mode: MobileHostPhonePushStatus.Mode
        public let admission: MobileHostPhonePushStatus.Admission
        public let queuePersistence:
            MobileHostPhonePushStatus.QueuePersistence
        public let apiOrigin: String
        public let accountVerified: Bool

        public init(
            forwardingEnabled: Bool,
            mode: MobileHostPhonePushStatus.Mode,
            admission: MobileHostPhonePushStatus.Admission = .allowed,
            queuePersistence:
                MobileHostPhonePushStatus.QueuePersistence = .healthy,
            apiOrigin: String,
            accountVerified: Bool
        ) {
            self.forwardingEnabled = forwardingEnabled
            self.mode = mode
            self.admission = admission
            self.queuePersistence = queuePersistence
            self.apiOrigin = apiOrigin
            self.accountVerified = accountVerified
        }

        public init(_ status: MobileHostPhonePushStatus) {
            self.init(
                forwardingEnabled: status.forwardingEnabled,
                mode: status.mode,
                admission: status.admission,
                queuePersistence: status.queuePersistence,
                apiOrigin: status.apiOrigin,
                accountVerified: status.accountScope == .verifiedSameAccount
            )
        }
    }

    /// The first gate that currently prevents end-to-end delivery.
    public enum Blocker: Equatable, Sendable {
        case phoneOptInDisabled
        case systemPermissionNotRequested
        case systemPermissionDenied
        case systemNotificationsUnsupported
        case awaitingDeviceToken
        case deviceTokenRegistrationFailed
        case registeringDevice
        case backendRegistrationRequired
        case authenticationRequired
        case accountDeletionInProgress
        case registrationRateLimited
        case deviceLimitReached(limit: Int)
        case networkUnavailable
        case pushServiceUnavailable
        case invalidConfiguration
        case invalidServerResponse
        case registrationRejected
        case macStatusUnavailable
        case macAccountMismatch
        case macForwardingDisabled
        case macCurrentlyActive
        case macAdmissionUnavailable
        case apiOriginMismatch
    }

    /// The concrete next action that repairs the current blocker.
    public enum Repair: Equatable, Sendable {
        case enableOnPhone
        case openSystemSettings
        case waitForDeviceToken
        case retryDeviceTokenRegistration
        case retryRegistration
        case signInAgain
        case finishAccountDeletion
        case disablePushOnAnotherDevice
        case connectMac
        case signIntoMatchingAccount
        case enableOnMac
        case leaveMacOrUseAlwaysMode
        case rebuildMatchingApps
    }

    /// The repair action for a blocked state, or `nil` when already ready.
    public var repair: Repair? {
        switch self {
        case .ready:
            return nil
        case .limited, .presentationLimited:
            return .openSystemSettings
        case .reliabilityLimited:
            return nil
        case let .blocked(blocker):
            return Self.repair(for: blocker)
        }
    }

    private static func repair(for blocker: Blocker) -> Repair {
        switch blocker {
        case .phoneOptInDisabled, .systemPermissionNotRequested:
            .enableOnPhone
        case .systemPermissionDenied, .systemNotificationsUnsupported:
            .openSystemSettings
        case .awaitingDeviceToken, .registeringDevice:
            .waitForDeviceToken
        case .deviceTokenRegistrationFailed:
            .retryDeviceTokenRegistration
        case .authenticationRequired:
            .signInAgain
        case .accountDeletionInProgress:
            .finishAccountDeletion
        case .deviceLimitReached:
            .disablePushOnAnotherDevice
        case .backendRegistrationRequired, .registrationRateLimited,
             .networkUnavailable,
             .pushServiceUnavailable, .invalidServerResponse,
             .registrationRejected:
            .retryRegistration
        case .invalidConfiguration, .apiOriginMismatch:
            .rebuildMatchingApps
        case .macStatusUnavailable:
            .connectMac
        case .macAccountMismatch:
            .signIntoMatchingAccount
        case .macForwardingDisabled:
            .enableOnMac
        case .macCurrentlyActive:
            .leaveMacOrUseAlwaysMode
        case .macAdmissionUnavailable:
            .connectMac
        }
    }

    /// Resolves the furthest confirmed stage in deterministic gate order.
    public static func resolve(
        authorization: MobilePushAuthorization,
        registration: PushRegistrationSnapshot,
        mac: MacStatus?,
        macAccountMismatch: Bool = false,
        systemSettings: MobilePushSystemSettings? = nil,
        phoneAPIOrigin: String
    ) -> MobilePushReadiness {
        let liveAuthorization = systemSettings?.authorization ?? authorization
        switch liveAuthorization {
        case .denied:
            return .blocked(.systemPermissionDenied)
        case .unsupported:
            return .blocked(.systemNotificationsUnsupported)
        case .notDetermined, .authorized, .provisional, .ephemeral:
            break
        }
        guard registration.isEnabled else {
            return .blocked(.phoneOptInDisabled)
        }
        guard liveAuthorization.permitsDelivery else {
            switch liveAuthorization {
            case .notDetermined:
                return .blocked(.systemPermissionNotRequested)
            case .denied:
                return .blocked(.systemPermissionDenied)
            case .unsupported:
                return .blocked(.systemNotificationsUnsupported)
            case .authorized, .provisional, .ephemeral:
                break
            }
            return .blocked(.systemNotificationsUnsupported)
        }
        switch registration.backendState {
        case .deviceTokenRegistrationFailed:
            return .blocked(.deviceTokenRegistrationFailed)
        case .awaitingDeviceToken:
            return .blocked(.awaitingDeviceToken)
        case .registrationRequired:
            return .blocked(.backendRegistrationRequired)
        case .registering:
            return .blocked(.registeringDevice)
        case .registered:
            break
        case let .failed(failure):
            return .blocked(blocker(for: failure))
        }
        guard registration.hasDeviceToken else {
            return .blocked(.awaitingDeviceToken)
        }
        if macAccountMismatch {
            return .blocked(.macAccountMismatch)
        }
        guard let mac else {
            return .blocked(.macStatusUnavailable)
        }
        guard mac.accountVerified else {
            return .blocked(.macAccountMismatch)
        }
        guard let macEndpoint = canonicalEndpoint(mac.apiOrigin),
              let phoneEndpoint = canonicalEndpoint(phoneAPIOrigin),
              macEndpoint == phoneEndpoint else {
            return .blocked(.apiOriginMismatch)
        }
        guard mac.forwardingEnabled else {
            return .blocked(.macForwardingDisabled)
        }
        switch mac.admission {
        case .allowed:
            break
        case .suppressedMacActive:
            return .blocked(.macCurrentlyActive)
        case .forwardingDisabled:
            return .blocked(.macForwardingDisabled)
        case .unknown:
            return .blocked(.macAdmissionUnavailable)
        }
        switch liveAuthorization {
        case .provisional, .ephemeral:
            return .limited(
                mode: mac.mode,
                authorization: liveAuthorization
            )
        case .notDetermined, .denied, .unsupported:
            return .blocked(.systemNotificationsUnsupported)
        case .authorized:
            break
        }
        if let limitations = systemSettings?.presentationLimitations,
           !limitations.isEmpty {
            return .presentationLimited(
                mode: mac.mode,
                limitations: limitations
            )
        }
        guard mac.queuePersistence == .healthy else {
            return .reliabilityLimited(
                mode: mac.mode,
                queuePersistence: mac.queuePersistence
            )
        }
        return .ready(mode: mac.mode)
    }

    private static func blocker(for failure: PushRegistrationFailure) -> Blocker {
        switch failure {
        case .authenticationRequired:
            .authenticationRequired
        case .accountDeletionInProgress:
            .accountDeletionInProgress
        case .rateLimited:
            .registrationRateLimited
        case let .deviceLimitReached(limit):
            .deviceLimitReached(limit: limit)
        case .networkUnavailable:
            .networkUnavailable
        case .serviceUnavailable:
            .pushServiceUnavailable
        case .invalidConfiguration:
            .invalidConfiguration
        case .invalidServerResponse:
            .invalidServerResponse
        case .rejected:
            .registrationRejected
        }
    }

    private static func canonicalEndpoint(_ rawValue: String) -> String? {
        guard var components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }
}
