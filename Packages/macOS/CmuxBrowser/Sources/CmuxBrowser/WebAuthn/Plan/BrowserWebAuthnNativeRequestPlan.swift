public import AuthenticationServices

/// The native authorization requests a WebAuthn ceremony should run, with the
/// presentation order and Bluetooth-preparation requirements derived from the
/// request's transports.
public struct BrowserWebAuthnNativeRequestPlan {
    public let platformRequests: [ASAuthorizationRequest]
    public let securityKeyRequests: [ASAuthorizationRequest]
    public let order: BrowserWebAuthnRequestOrder
    public let needsBluetoothForPlatformRequests: Bool
    public let needsBluetoothForSecurityKeyRequests: Bool
    public let prefersImmediatelyAvailableCredentials: Bool

    public init(
        platformRequests: [ASAuthorizationRequest],
        securityKeyRequests: [ASAuthorizationRequest],
        order: BrowserWebAuthnRequestOrder,
        needsBluetoothForPlatformRequests: Bool,
        needsBluetoothForSecurityKeyRequests: Bool,
        prefersImmediatelyAvailableCredentials: Bool
    ) {
        self.platformRequests = platformRequests
        self.securityKeyRequests = securityKeyRequests
        self.order = order
        self.needsBluetoothForPlatformRequests = needsBluetoothForPlatformRequests
        self.needsBluetoothForSecurityKeyRequests = needsBluetoothForSecurityKeyRequests
        self.prefersImmediatelyAvailableCredentials = prefersImmediatelyAvailableCredentials
    }

    public var hasPlatformRequests: Bool {
        !platformRequests.isEmpty
    }

    public var hasSecurityKeyRequests: Bool {
        !securityKeyRequests.isEmpty
    }

    /// The ordered authorization requests to perform, optionally excluding the
    /// platform requests when platform authorization is unavailable.
    public func authorizationRequests(includePlatformRequests: Bool) -> [ASAuthorizationRequest] {
        switch order {
        case .platformFirst:
            return (includePlatformRequests ? platformRequests : []) + securityKeyRequests
        case .securityKeyFirst:
            return securityKeyRequests + (includePlatformRequests ? platformRequests : [])
        }
    }

    /// Whether Bluetooth must be prepared before performing the selected requests.
    public func needsBluetoothPreparation(includePlatformRequests: Bool) -> Bool {
        (includePlatformRequests && needsBluetoothForPlatformRequests) ||
            (hasSecurityKeyRequests && needsBluetoothForSecurityKeyRequests)
    }
}
