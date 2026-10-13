import AppKit
import CmuxNextControl
import CmuxNextDaemonService
import CmuxNextMobile
import CmuxNextPhonePairing
import Foundation
import os

/// Phone access over WireGuard, independent of sign-in: the in-process
/// WireGuard host starts at launch and the "Open Mobile Pairing" action
/// shows its QR code. Each tagged build keeps its own host identity under
/// its bundle id's state directory.
@MainActor
final class PhonePairingService {
    private(set) var host: WireGuardPhoneHost?
    let model = PhonePairingModel()
    private var controller: PhonePairingWindowController?
    private let advertiser = WireGuardBonjourAdvertiser()
    private var starting: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.phone-pairing")

    init() {
        model.onNewCode = { [weak self] in self?.mintCode() }
        model.onRevoke = { [weak self] id in self?.revoke(id) }
    }

    func start(launch: LaunchIdentity, daemon: DaemonService) {
        guard host == nil, starting == nil else { return }
        let namespace = launch.bundleID ?? "com.cmuxterm.app.next"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(namespace, isDirectory: true)
        starting = Task { [weak self] in
            let name = await MacName.computerName()
            guard let self, !Task.isCancelled else { return }
            let host = WireGuardPhoneHost(
                stateDirectory: directory, hostName: name,
                daemonSocketPath: { @MainActor in try? await daemon.endpoint().socketPath },
                onChange: { [weak self] snapshot in
                    // task-owner: hop to the main actor to update the window model
                    Task { @MainActor in self?.apply(snapshot) }
                })
            self.host = host
            await host.start()
            self.starting = nil
            if self.controller != nil { self.mintCode() }
        }
    }

    func stop() {
        advertiser.stop()
        starting?.cancel()
        starting = nil
        let host = host
        self.host = nil
        // task-owner: teardown hop; WireGuardPhoneHost.stop() is idempotent
        Task { await host?.stop() }
    }

    /// Shows the pairing window with a fresh code.
    func present() {
        if controller == nil {
            let controller = PhonePairingWindowController(model: model)
            controller.onClose = { [weak self] in
                self?.controller = nil
                self?.model.link = nil
                self?.model.justPaired = nil
                // task-owner: drops the unused invitation's bootstrap peer
                Task { await self?.host?.cancelInvitation() }
            }
            self.controller = controller
        }
        mintCode()
        controller?.present()
    }

    private func mintCode() {
        guard let host else { return }
        // task-owner: one invitation mint; the result lands in the window model
        Task { [weak self, logger] in
            do {
                let invitation = try await host.makeInvitation()
                self?.model.link = invitation.link
                self?.model.expiresAt = invitation.expiry
                self?.model.justPaired = nil
            } catch {
                logger.error("pairing code failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func revoke(_ id: String) {
        guard let host else { return }
        // task-owner: one revocation; the host publishes the new list
        Task { try? await host.revoke(phoneID: id) }
    }

    private func apply(_ snapshot: WireGuardPhoneHost.Snapshot) {
        if snapshot.running, let port = snapshot.listenPort, !snapshot.hostID.isEmpty {
            advertiser.publish(name: snapshot.hostName, hostID: snapshot.hostID, port: port)
        } else {
            advertiser.stop()
        }
        model.failure = snapshot.failure
        model.endpoints = snapshot.endpoints
        model.hostFingerprint = snapshot.hostKeyFingerprint
        model.phones = snapshot.phones.sorted { $0.pairedAt > $1.pairedAt }.map { phone in
            PhonePairingModel.Phone(id: phone.id, name: phone.name, model: phone.model, address: phone.address,
                                    connected: (snapshot.connections[phone.id] ?? 0) > 0,
                                    lastSeen: snapshot.lastHandshake[phone.id])
        }
        if let paired = snapshot.justPaired, controller != nil {
            model.justPaired = paired.name
            model.link = nil
        }
    }
}
