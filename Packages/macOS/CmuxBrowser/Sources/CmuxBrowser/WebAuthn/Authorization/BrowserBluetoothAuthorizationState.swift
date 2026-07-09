import CoreBluetooth

/// A snapshot of Core Bluetooth authorization and power state for the WebAuthn bridge.
///
/// Captures the process's `CBManagerAuthorization` plus the central manager's
/// `CBManagerState` (nil before a manager exists) and derives whether hybrid
/// (caBLE) transport can be advertised to the page.
@MainActor
public struct BrowserBluetoothAuthorizationState {
    let authorization: CBManagerAuthorization
    let managerState: CBManagerState?

    init(authorization: CBManagerAuthorization, managerState: CBManagerState?) {
        self.authorization = authorization
        self.managerState = managerState
    }

    /// Whether Bluetooth access has been granted for this process.
    public var isAuthorized: Bool {
        authorization == .allowedAlways
    }

    /// Whether the Bluetooth radio is powered on, or nil when no manager state is known yet.
    public var isPoweredOn: Bool? {
        guard let managerState else { return nil }
        return managerState == .poweredOn
    }

    /// Whether hybrid (caBLE) transport can be offered given the current authorization and power state.
    public var canUseHybridTransport: Bool {
        switch authorization {
        case .denied, .restricted:
            return false
        case .allowedAlways:
            guard let managerState else { return true }
            return managerState != .poweredOff
        case .notDetermined:
            return true
        @unknown default:
            return false
        }
    }
}
