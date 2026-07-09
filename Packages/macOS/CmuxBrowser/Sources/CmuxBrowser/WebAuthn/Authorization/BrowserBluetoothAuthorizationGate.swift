import Foundation
public import CoreBluetooth

/// Coalesces Core Bluetooth authorization and power-up for the browser's WebAuthn bridge.
///
/// Lazily creates a `CBCentralManager` (which surfaces the system Bluetooth power
/// alert), deduplicates concurrent prepare requests onto a single in-flight prompt,
/// and primes one no-op scan so the radio reports `.poweredOn` before a hybrid
/// (caBLE) ceremony begins.
@MainActor
public final class BrowserBluetoothAuthorizationGate: NSObject, @preconcurrency CBCentralManagerDelegate {
    public static let shared = BrowserBluetoothAuthorizationGate()

    private var centralManager: CBCentralManager?
    private var inFlightRequest: Task<BrowserBluetoothAuthorizationState, Never>?
    private var pendingContinuation: CheckedContinuation<BrowserBluetoothAuthorizationState, Never>?
    private var hasPrimedBluetoothActivity = false

    /// The current Bluetooth authorization and power snapshot, read without prompting.
    public func currentState() -> BrowserBluetoothAuthorizationState {
        .init(
            authorization: CBCentralManager.authorization,
            managerState: centralManager?.state
        )
    }

    /// Prepares Bluetooth when it is still undetermined or not yet powered on, coalescing
    /// concurrent callers onto a single prompt and returning the resolved snapshot.
    public func prepareIfNeeded() async -> BrowserBluetoothAuthorizationState {
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

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
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
