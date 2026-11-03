public import Foundation
public import Observation

/// The opt-in Cloud Tunnel's one state machine: Settings, `cmux cloud tunnel on|off|status` and
/// MCP all go through it.
///
/// Off by default, and while off it never touches SystemExtensions or NetworkExtension. An
/// explicit ``enable()`` requests the extension's activation (macOS asks the user once), enrolls
/// the `browser` peer, saves the VPN configuration and starts it. A launch with the setting on
/// (``restore(enabled:)``) starts the configuration a previous opt-in saved; its activation
/// request only replaces an extension the user already allowed, so a launch never asks.
///
/// ```swift
/// let tunnel = CloudTunnelController(
///     availability: .available(extensionIdentifier: "com.cmuxterm.app.tunnel"),
///     activator: LiveSystemExtensionActivator(),
///     manager: LiveTunnelManager(),
///     enroller: enroller
/// )
/// await tunnel.enable()
/// ```
@MainActor
@Observable
public final class CloudTunnelController {
    /// Whether this build can run the tunnel.
    public enum Availability: Sendable, Equatable {
        /// The app bundles the extension and is signed to install it.
        case available(extensionIdentifier: String)
        /// It cannot; the text says why (shown as the status reason).
        case unavailable(String)
    }

    /// The tunnel's status, updated as it changes.
    public private(set) var status: CloudTunnelStatus = .off

    private let availability: Availability
    private let activator: any SystemExtensionActivating
    private let manager: any TunnelManaging
    private let enroller: any CloudTunnelEnrolling
    /// Whether the user wants the tunnel up; a disconnect then is a failure, not "off".
    private var wantsUp = false
    /// Set once the started configuration reported progress, so the initial `disconnected` a
    /// fresh start reports is not taken for a failure.
    private var started = false
    private var stateWatch: Task<Void, Never>?

    /// - Parameters:
    ///   - availability: Whether the bundle carries a usable extension (decided once at launch).
    ///   - activator: Submits the activation request.
    ///   - manager: The saved VPN configuration.
    ///   - enroller: Enrolls the `browser` peer.
    public init(
        availability: Availability,
        activator: any SystemExtensionActivating,
        manager: any TunnelManaging,
        enroller: any CloudTunnelEnrolling
    ) {
        self.availability = availability
        self.activator = activator
        self.manager = manager
        self.enroller = enroller
        if case .unavailable(let reason) = availability { status = .unavailable(reason) }
    }

    /// Turns the tunnel on: activation (asking the user when needed), a fresh peer, start.
    /// Returns once the tunnel is starting, waiting for approval, or failed.
    public func enable() async {
        await start(reuseSaved: false)
    }

    /// Applies the saved setting at launch. Off: nothing at all. On: starts the configuration a
    /// previous opt-in saved; when there is none (the user quit before approving), it waits for
    /// an explicit ``enable()`` instead of asking at launch.
    public func restore(enabled: Bool) async {
        guard enabled, case .available = availability else { return }
        let saved: Bool
        do {
            saved = try await manager.loadSaved()
        } catch {
            status = .failed(Self.message(error))
            return
        }
        guard saved else {
            status = .failed(String(
                localized: "cloudTunnel.status.finishSetup",
                defaultValue: "Setup was not finished. Turn the Cloud Tunnel on again.",
                bundle: .module
            ))
            return
        }
        await start(reuseSaved: true)
    }

    /// Turns the tunnel off and removes its VPN configuration. The extension stays installed
    /// (removing it needs the user's password), idle.
    public func disable() async {
        wantsUp = false
        stateWatch?.cancel()
        stateWatch = nil
        guard case .available = availability else { return }
        status = .disconnecting
        manager.stop()
        do {
            try await manager.remove()
            status = .off
        } catch {
            status = .failed(Self.message(error))
        }
    }

    private func start(reuseSaved: Bool) async {
        guard case .available(let identifier) = availability else { return }
        wantsUp = true
        started = false
        status = .connecting
        guard await activate(identifier) else { return }
        guard wantsUp else { return }
        status = .connecting
        do {
            let saved = try await manager.loadSaved()
            if !(reuseSaved && saved) {
                let wgQuick = try await enroller.enrollBrowserPeer()
                let configuration = try CloudTunnelConfiguration(wgQuick: wgQuick)
                try await manager.install(configuration, providerBundleIdentifier: identifier)
            }
            guard wantsUp else { return }
            watchStates()
            try manager.start()
        } catch {
            wantsUp = false
            status = .failed(Self.message(error))
        }
    }

    /// Runs the activation request; `false` when it did not end activated (status says why).
    private func activate(_ identifier: String) async -> Bool {
        for await event in activator.activate(identifier: identifier) {
            switch event {
            case .needsApproval:
                status = .awaitingApproval
            case .activated:
                return true
            case .willCompleteAfterReboot:
                wantsUp = false
                status = .failed(String(
                    localized: "cloudTunnel.status.reboot",
                    defaultValue: "Restart your Mac to finish installing the cmux Cloud Tunnel.",
                    bundle: .module
                ))
                return false
            case .failed(let reason):
                wantsUp = false
                status = .failed(reason)
                return false
            }
        }
        wantsUp = false
        status = .failed(String(
            localized: "cloudTunnel.status.activationEnded",
            defaultValue: "macOS did not finish installing the cmux Cloud Tunnel.",
            bundle: .module
        ))
        return false
    }

    private func watchStates() {
        stateWatch?.cancel()
        let states = manager.states()
        // task-owner: the controller; cancelled by disable() or the next start.
        stateWatch = Task { [weak self] in
            for await state in states {
                guard !Task.isCancelled, let self else { return }
                self.apply(state)
            }
        }
    }

    private func apply(_ state: CloudTunnelConnectionState) {
        switch state {
        case .connecting, .reasserting:
            started = true
            status = .connecting
        case .connected(let since):
            started = true
            status = .connected(since: since)
        case .disconnecting:
            status = .disconnecting
        case .disconnected, .invalid:
            guard started else { return }
            status = wantsUp
                ? .failed(String(
                    localized: "cloudTunnel.status.stopped",
                    defaultValue: "The Cloud Tunnel stopped. Turn it off and on to retry.",
                    bundle: .module
                ))
                : .off
        }
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
