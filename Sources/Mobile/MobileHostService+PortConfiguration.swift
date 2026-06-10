import CMUXMobileCore
import CmuxAuthRuntime
import CmuxSettings
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth
import os


// MARK: - Port & Listening-Enabled Configuration
extension MobileHostService {
    /// User-default key for the opt-in Mac-side iOS pairing listener.
    nonisolated static let listeningEnabledDefaultsKey = SettingCatalog().mobile.iOSPairingHost.userDefaultsKey

    /// Whether the mobile pairing host should bind a network listener at all.
    ///
    /// Defaults off in every build so macOS does not ask for Local Network
    /// permission until the user enables iOS pairing in Settings.
    nonisolated static var isListeningEnabled: Bool {
        isListeningEnabled(defaults: .standard)
    }

    #if DEBUG
    nonisolated static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCInjectBundle"] != nil
            || environment["XCInjectBundleInto"] != nil
            || environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true
    }
    #endif

    nonisolated static func isListeningEnabled(defaults: UserDefaults) -> Bool {
        if let override = defaults.object(forKey: listeningEnabledDefaultsKey) as? Bool {
            return override
        }
        return SettingCatalog().mobile.iOSPairingHost.defaultValue
    }

    /// User-default key for the preferred iOS pairing listener port.
    nonisolated static let portDefaultsKey = SettingCatalog().mobile.iOSPairingPort.userDefaultsKey

    /// The preferred TCP port the listener should try to bind, read from
    /// settings.
    ///
    /// Falls back to the catalog default (which mirrors
    /// `CmxMobileDefaults.defaultHostPort`) when unset or outside the valid
    /// `1...65535` range. The listener still falls back to an OS-assigned
    /// ephemeral port if this port is unavailable at bind time.
    nonisolated static func configuredPort(defaults: UserDefaults = .standard) -> Int {
        let fallback = SettingCatalog().mobile.iOSPairingPort.defaultValue
        guard let raw = defaults.object(forKey: portDefaultsKey) as? Int else {
            return fallback
        }
        return (1...65535).contains(raw) ? raw : fallback
    }

    /// The port a settings change should reconcile the *running* listener to, or
    /// `nil` when the stored value is present but out of range.
    ///
    /// Distinguished from ``configuredPort(defaults:)`` so an invalid value the
    /// user is still editing (the field shows a warning) does not tear down a
    /// running listener and silently rebind it to the default port. Returns the
    /// catalog default when unset, the override when valid, and `nil` when the
    /// stored value is out of range.
    nonisolated static func resolvedDesiredPort(defaults: UserDefaults = .standard) -> Int? {
        guard let raw = defaults.object(forKey: portDefaultsKey) as? Int else {
            return SettingCatalog().mobile.iOSPairingPort.defaultValue
        }
        return (1...65535).contains(raw) ? raw : nil
    }

    /// Pure reconciliation between the desired settings and the live listener
    /// state. Factored out so the restart-on-port-change decision is unit
    /// testable without binding a real `NWListener`.
    ///
    /// - Parameters:
    ///   - enabled: Whether the iOS pairing host is enabled in settings.
    ///   - listenerRunning: Whether a listener is currently bound.
    ///   - desiredPort: The preferred port from settings (``configuredPort(defaults:)``).
    ///   - appliedPort: The preferred port the running listener targeted, or
    ///     `nil` when stopped.
    /// - Returns: The action ``syncToSettings()`` should take.
    nonisolated static func syncDecision(
        enabled: Bool,
        listenerRunning: Bool,
        desiredPort: Int,
        appliedPort: Int?
    ) -> MobileHostSyncDecision {
        guard enabled else { return listenerRunning ? .stop : .noop }
        guard listenerRunning else { return .start }
        if appliedPort != desiredPort { return .restart }
        return .noop
    }

    /// Pure pre-bind classification for an explicit "Apply port" request. Returns
    /// the outcome for the cases that need no bind attempt, or `nil` when a real
    /// bind must be tried (pairing on, valid port, different from the bound one).
    /// Factored out so the decision is unit-testable without a real `NWListener`.
    ///
    /// - Parameters:
    ///   - enabled: Whether iOS pairing is enabled in settings.
    ///   - currentBoundPort: The port the listener is currently bound to, or `nil`.
    ///   - requestedPort: The port the user asked to apply.
    nonisolated static func portApplyPreBindOutcome(
        enabled: Bool,
        currentBoundPort: Int?,
        requestedPort: Int
    ) -> MobileHostPortApplyOutcome? {
        guard (1...65535).contains(requestedPort) else { return .invalid }
        guard enabled else { return .savedWhileDisabled }
        if currentBoundPort == requestedPort { return .applied(requestedPort) }
        return nil
    }

    /// Whether `error` means the address/port cannot be bound (in use, not
    /// available, or permission denied) versus a transient waiting reason.
    nonisolated static func isAddressUnavailable(_ error: NWError) -> Bool {
        if case let .posix(code) = error {
            return code == .EADDRINUSE || code == .EADDRNOTAVAIL || code == .EACCES
        }
        return false
    }

    /// Applies an explicitly-requested pairing port.
    ///
    /// Make-before-break: when a running listener must move to a different port, a
    /// candidate listener is bound on that port *first*; only if it actually binds
    /// is the old listener torn down and the candidate adopted. So an in-use port
    /// leaves the running listener and its connections untouched (no probe →
    /// rebind gap that could drop connections). Operates on `UserDefaults.standard`
    /// since it persists to and rebinds the live singleton listener.
    func applyConfiguredPort(_ port: Int) async -> MobileHostPortApplyOutcome {
        let defaults = UserDefaults.standard
        if let preBind = Self.portApplyPreBindOutcome(
            enabled: Self.isListeningEnabled(defaults: defaults),
            currentBoundPort: listenerPort,
            requestedPort: port
        ) {
            switch preBind {
            case .invalid, .portInUse:
                break
            case .savedWhileDisabled, .applied:
                defaults.set(port, forKey: Self.portDefaultsKey)
            }
            return preBind
        }
        // A real bind is required (pairing on, valid port, different from bound).
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return .invalid }
        guard let candidate = await bindReadyCandidate(on: endpointPort, generation: UUID()) else {
            return .portInUse
        }
        adoptCandidateListener(candidate.listener, generation: candidate.generation, port: port)
        defaults.set(port, forKey: Self.portDefaultsKey)
        return .applied(port)
    }

    /// Reconcile the live listener with current settings (enable/disable and
    /// preferred-port changes). Safe to call on any settings change: it no-ops
    /// unless the enabled state or the configured port actually changed, so an
    /// unrelated `UserDefaults` write does not drop active iOS connections.
    ///
    /// Reads `UserDefaults.standard` because the live singleton listener binds
    /// against the app's real store; `start`/`restart` do the same, so there is
    /// no caller-supplied store to honor here.
    func syncToSettings() {
        let defaults = UserDefaults.standard
        // An invalid stored port (`resolvedDesiredPort == nil`, e.g. mid-edit)
        // must not restart a running listener. Treat it as "no change" by
        // reusing the applied port; a fresh start still binds the default via
        // `configuredPort()`.
        let desiredPort = Self.resolvedDesiredPort(defaults: defaults)
            ?? appliedPreferredPort
            ?? Self.configuredPort(defaults: defaults)
        switch Self.syncDecision(
            enabled: Self.isListeningEnabled(defaults: defaults),
            listenerRunning: listener != nil,
            desiredPort: desiredPort,
            appliedPort: appliedPreferredPort
        ) {
        case .noop:
            break
        case .start:
            start()
        case .stop:
            stop()
        case .restart:
            restart()
        }
    }

}
