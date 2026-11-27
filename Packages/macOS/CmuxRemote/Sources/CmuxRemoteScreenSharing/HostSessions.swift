// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxDeviceHub
import CmuxVNCWebRTC
import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "screen-sessions")

extension DeviceIdentity: @retroactive ScreenTicketSigner {
    public func deviceHeaders(for url: URL) async throws -> [String: String] {
        try DeviceRequestSigner(identity: self).headers(method: "GET", pathAndQuery: DeviceRequestSigner.pathAndQuery(of: url), body: nil)
    }
}

/// This Mac's Mac Screen sessions (the app's MacScreenHubHost, moved into
/// the Screen Sharing worker): each `session.ticket` for the host role is
/// served by its own `ScreenStreamHost` (View Only passes no input) over the
/// ticket's signaling; a revocation or end closes it at once. One session at
/// a time: a newer one replaces the older.
@MainActor
final class HostSessions {
    struct Session: Equatable {
        var id: String
        var viewerID: String
        var viewerName: String
        var scope: SessionScope
        var connected: Bool

        var fields: [String: Any] {
            ["id": id, "viewer_id": viewerID, "viewer_name": viewerName, "scope": scope.rawValue, "connected": connected]
        }
    }

    private(set) var session: Session?
    private var host: ScreenStreamHost?
    private var eventTask: Task<Void, Never>?
    var hub: () -> DeviceHub? = { nil }
    /// Whether this Mac's local consent allows a session of a scope (the app's join consent, as last told).
    var permits: (SessionScope) -> Bool = { _ in true }
    var changed: () -> Void = {}

    /// `session.ticket` for the host role.
    func serve(_ ticket: SessionTicket) {
        guard ticket.role == .host, let hub = hub() else { return }
        guard permits(ticket.scope) else {
            logger.info("session ticket refused: this Mac's consent does not allow it")
            end(ticket.sessionId, reason: "failed", hub: hub)
            return
        }
        if let current = session, current.id != ticket.sessionId {
            closeLocal()
            end(current.id, reason: "replaced", hub: hub)
        }
        let signaling: TicketSignaling
        do {
            signaling = try TicketSignaling(ticket: ticket.ticket, signalURL: ticket.signalURL, signer: hub.identity,
                                            iceServers: hub.iceServers(for: ticket).map {
                                                ICEServerConfig(urls: $0.urls, username: $0.username, credential: $0.credential)
                                            }, expectedPeerKey: ticket.peer.signingKey)
        } catch {
            logger.error("session ticket refused: \(String(describing: error), privacy: .public)")
            end(ticket.sessionId, reason: "failed", hub: hub)
            return
        }
        let log: @Sendable (String) -> Void = { line in logger.info("\(line, privacy: .public)") }
        let host = ScreenStreamHost(name: Host.current().localizedName ?? "Mac", viewOnly: ticket.scope == .view,
                                    backend: { ScreenCaptureBackend(log: log) }, log: log)
        let (events, sink) = AsyncStream.makeStream(of: ScreenStreamHost.Event.self, bufferingPolicy: .bufferingNewest(64))
        host.onEvent = { sink.yield($0) }
        self.host = host
        session = Session(id: ticket.sessionId, viewerID: ticket.peer.id, viewerName: ticket.peer.name, scope: ticket.scope, connected: false)
        let id = ticket.sessionId
        eventTask = Task { [weak self, weak host] in
            for await event in events {
                guard let self, let host, self.host === host else { return }
                handle(event, session: id)
            }
        }
        Task.detached { [weak self] in
            try? await host.serve(signaling)
            await self?.served(host, session: id)
        }
        logger.info("serving a device hub session (\(ticket.scope.rawValue, privacy: .public))")
        changed()
    }

    /// `session.revoked` or `session.ended`.
    func sessionOver(_ id: String) {
        guard session?.id == id else { return }
        closeLocal()
    }

    /// The local consent changed: a session it no longer allows stops.
    func consentChanged() {
        guard let current = session, !permits(current.scope) else { return }
        stop(reason: "host_stopped")
    }

    /// Stop Sharing This Mac: the hub hears it first, then the stream closes.
    func stop(reason: String = "host_stopped") {
        guard let current = session else { return }
        guard let hub = hub() else { return closeLocal() }
        Task { [weak self] in
            try? await hub.endSession(current.id, reason: reason)
            guard let self, session?.id == current.id else { return }
            closeLocal()
        }
    }

    /// Revoke This Device: its access becomes None; the hub's revocation push closes the session.
    func revokeViewer() {
        guard let current = session, let hub = hub() else { return }
        Task { [weak self] in
            do { try await hub.setPermission(host: hub.identity.id, viewer: current.viewerID, scope: .none) } catch {
                self?.stop()
            }
        }
    }

    func closeAll() { closeLocal() }

    private func handle(_ event: ScreenStreamHost.Event, session id: String) {
        guard session?.id == id else { return }
        switch event {
        case .viewerConnected:
            session?.connected = true
            changed()
        case .viewerEnded:
            closeLocal()
        case let .sourceFailed(message):
            logger.error("screen capture failed: \(message, privacy: .public)")
            stop(reason: "failed")
        case .waiting, .roomLost:
            break
        }
    }

    private func served(_ host: ScreenStreamHost, session id: String) {
        guard self.host === host, let current = session, current.id == id, !current.connected else { return }
        closeLocal()
    }

    private func closeLocal() {
        let host = self.host
        self.host = nil
        host?.onEvent = nil
        // Closing the peer connection waits on WebRTC's threads: never on the main actor.
        if let host { Task.detached { host.disconnectViewer() } }
        eventTask?.cancel()
        eventTask = nil
        session = nil
        changed()
    }

    private func end(_ id: String, reason: String, hub: DeviceHub) {
        Task { try? await hub.endSession(id, reason: reason) }
    }

    /// The menu bar line for the session, nil while no device is connected.
    var indicatorTitle: String? {
        guard let session, session.connected else { return nil }
        return String(format: session.scope == .view
            ? RemoteText.t("macScreen.indicator.viewing", "%@ is viewing this Mac")
            : RemoteText.t("macScreen.indicator.controlling", "%@ is controlling this Mac"), session.viewerName)
    }
}
