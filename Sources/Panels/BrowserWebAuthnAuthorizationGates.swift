import AppKit
import AuthenticationServices
import Bonsplit
import CoreBluetooth
import Foundation
import ObjectiveC.runtime
import WebKit


// MARK: - Bluetooth & Platform Passkey Authorization Gates
@MainActor
struct BrowserBluetoothAuthorizationState {
    let authorization: CBManagerAuthorization
    let managerState: CBManagerState?

    var isAuthorized: Bool {
        authorization == .allowedAlways
    }

    var isPoweredOn: Bool? {
        guard let managerState else { return nil }
        return managerState == .poweredOn
    }

    var canUseHybridTransport: Bool {
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

@MainActor
final class BrowserBluetoothAuthorizationGate: NSObject, @preconcurrency CBCentralManagerDelegate {
    static let shared = BrowserBluetoothAuthorizationGate()

    private var centralManager: CBCentralManager?
    private var inFlightRequest: Task<BrowserBluetoothAuthorizationState, Never>?
    private var pendingContinuation: CheckedContinuation<BrowserBluetoothAuthorizationState, Never>?
    private var hasPrimedBluetoothActivity = false

    func currentState() -> BrowserBluetoothAuthorizationState {
        .init(
            authorization: CBCentralManager.authorization,
            managerState: centralManager?.state
        )
    }

    func prepareIfNeeded() async -> BrowserBluetoothAuthorizationState {
        let currentState = currentState()
        switch currentState.authorization {
        case .denied, .restricted:
            return currentState
        case .allowedAlways where currentState.managerState == .poweredOn:
            return currentState
        default:
            break
        }

        if let inFlightRequest {
            return await inFlightRequest.value
        }

        let request = Task { @MainActor in
            await withCheckedContinuation { continuation in
                pendingContinuation = continuation
                if let centralManager {
                    centralManagerDidUpdateState(centralManager)
                } else {
                    centralManager = CBCentralManager(
                        delegate: self,
                        queue: nil,
                        options: [CBCentralManagerOptionShowPowerAlertKey: true]
                    )
                }
            }
        }

        inFlightRequest = request
        let result = await request.value
        inFlightRequest = nil
        return result
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = BrowserBluetoothAuthorizationState(
            authorization: CBCentralManager.authorization,
            managerState: central.state
        )

        switch state.authorization {
        case .notDetermined:
            return
        case .allowedAlways:
            primeBluetoothActivityIfNeeded(with: central)
            finish(with: state)
        case .denied, .restricted:
            finish(with: state)
        @unknown default:
            finish(with: state)
        }
    }

    private func primeBluetoothActivityIfNeeded(with central: CBCentralManager) {
        guard !hasPrimedBluetoothActivity, central.state == .poweredOn else { return }
        hasPrimedBluetoothActivity = true
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        central.stopScan()
    }

    private func finish(with state: BrowserBluetoothAuthorizationState) {
        pendingContinuation?.resume(returning: state)
        pendingContinuation = nil
    }
}

@MainActor
final class BrowserPasskeyAuthorizationGate {
    static let shared = BrowserPasskeyAuthorizationGate()

    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    private var inFlightRequest: Task<ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState, Never>?

    func currentAuthorizationState() -> ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        manager.authorizationStateForPlatformCredentials
    }

    func authorizeIfNeeded() async -> ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        let currentState = manager.authorizationStateForPlatformCredentials
        guard currentState == .notDetermined else { return currentState }

        if let inFlightRequest {
            return await inFlightRequest.value
        }

        let request = Task { @MainActor [manager] in
            await withCheckedContinuation { continuation in
                manager.requestAuthorizationForPublicKeyCredentials { authorizationState in
                    continuation.resume(returning: authorizationState)
                }
            }
        }

        inFlightRequest = request
        let result = await request.value
        inFlightRequest = nil
        return result
    }
}

