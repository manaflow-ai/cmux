// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxDeviceHub
import CmuxRemoteWire
import CryptoKit
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "screen-sharing")

/// The Screen Sharing worker (`cmux-remote worker screen-sharing`): a child of
/// the cmux Remote host, so macOS checks its Screen Recording and
/// Accessibility as cmux Remote's. Its stdin and stdout are the host's
/// control lines; its socket (`w-screen.sock`, only the host may connect)
/// serves the app's channels, which the host splices through. Every Mac Screen
/// capture runs here: a channel whose first request is `session.rd` or
/// `session.webrtc` is one session the app serves (``AttachedScreenSession``),
/// so the cmux app itself never captures the screen or injects input.
@MainActor
public final class ScreenSharingWorker: NSObject, NSApplicationDelegate {
    let layout: RemoteHostLayout
    let agent: DeviceAgent
    private let control = LineChannel(read: STDIN_FILENO, write: STDOUT_FILENO)
    private var statusQueued = false
    private(set) var appChannels = 0
    /// The app's hub subscriptions, by channel.
    private var subscribers: [ObjectIdentifier: LineChannel] = [:]
    /// `cmux-screen-sharing` (the cmux.rd/1 host) beside this executable, in the same signed
    /// helper; nil when this helper carries none (cmux.rd/1 viewers are then refused, WebRTC serves).
    let rdExecutable: String?

    public init(layout: RemoteHostLayout, stateDirectory: String, keychainScope: String, headless: Bool,
                rdExecutable: String? = ScreenSharingWorker.bundledRdExecutable()) {
        self.layout = layout
        self.rdExecutable = rdExecutable
        agent = DeviceAgent(keychainScope: keychainScope, statePath: stateDirectory + "/screen-sharing.json", headless: headless)
        super.init()
        agent.changed = { [weak self] in self?.queueStatus() }
    }

    /// `cmux-screen-sharing` in this executable's folder (`Contents/MacOS` of the helper), if any.
    public nonisolated static func bundledRdExecutable() -> String? {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let path = executable.deletingLastPathComponent().appendingPathComponent("cmux-screen-sharing").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Never returns.
    public func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        startControl()
        startSocket()
        Task { await agent.start() }
        app.run()
        exit(0)
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Only the host stops a worker (its stdin ends).
        .terminateCancel
    }

    // MARK: Host control

    private func startControl() {
        let control = self.control
        let thread = Thread { [weak self] in
            while let object = control.readObject() {
                let request = WorkerRequest(object)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    control.write(await handle(request.method, request.params, id: request.id))
                }
            }
            // The host closed our stdin: end the session for the viewer, then exit.
            Task { @MainActor [weak self] in
                self?.agent.sessions.stop()
                exit(0)
            }
        }
        thread.name = "remote-screen-control"
        thread.start()
        queueStatus()
    }

    /// One `status` event per main run loop turn, however many changes it had.
    private func queueStatus() {
        guard !statusQueued else { return }
        statusQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusQueued = false
            control.write(RemoteWire.event("status", ["status": agent.status]))
        }
    }

    func handle(_ method: String, _ params: [String: Any], id: Any?) async -> Data {
        switch method {
        case "status":
            return RemoteWire.answer(id: id, result: agent.status)
        case "share":
            guard params["on"] as? Bool == false else {
                return RemoteWire.failure(id: id, code: "needs_app", message: "Share This Mac on is confirmed in cmux (palette: Share This Mac)")
            }
            switch await agent.shareOff() {
            case let .success(shared): return RemoteWire.answer(id: id, result: ["sharing": shared])
            case let .failure(error): return RemoteWire.failure(id: id, code: error.code?.rawValue ?? "failed", message: error.description)
            }
        case "access":
            guard let device = params["device"] as? String, let scope = (params["scope"] as? String).flatMap(DeviceScope.init(rawValue:)) else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "device and scope (none, ask, view, full) are required")
            }
            switch await agent.setAccess(viewer: device, scope: scope) {
            case let .success(scope): return RemoteWire.answer(id: id, result: ["device": device, "access": scope.rawValue])
            case let .failure(error): return RemoteWire.failure(id: id, code: error.code?.rawValue ?? "failed", message: error.description)
            }
        case "stop_session":
            // While the app is attached it stops what it serves; a session that serves on after the
            // app left (headless) is this worker's to stop.
            guard !agent.relayOnly || (agent.sessions.session != nil && !agent.sessions.appOwnsSession) else {
                return RemoteWire.failure(id: id, code: "screen.app_host",
                                          message: "the cmux app owns Mac Screen sharing")
            }
            agent.sessions.stop()
            return RemoteWire.answer(id: id, result: [:])
        default:
            return RemoteWire.failure(id: id, code: "unknown_method", message: "unknown method \(method)")
        }
    }

    // MARK: App channels

    private func startSocket() {
        let listener: Int32
        do { listener = try LocalSocket.listen(layout.screenSharingSocket) } catch {
            logger.error("worker socket: \(String(describing: error), privacy: .public)")
            return
        }
        LocalSocket.serve(listener, name: "remote-screen-app") { [weak self] channel in
            // Only the host connects here (it splices the app's channel through).
            guard channel.peer?.pid == getppid() else { return channel.close() }
            guard let object = channel.readObject() else { return channel.close() }
            let first = WorkerRequest(object)
            // One session the app serves: this channel is that session's from now on.
            if AttachedScreenSession.Kind(rawValue: first.method) != nil {
                Task { @MainActor [weak self] in
                    guard let self else { return channel.close() }
                    attach(first, channel: channel)
                }
                return
            }
            // The reader stays off the main actor, while one actor task owns this
            // channel's registration, request order, and teardown. This prevents
            // a queued request from racing appChannelClosed and re-enabling worker
            // hosting after the app has gone away.
            let stream = AsyncStream<WorkerRequest>.makeStream(bufferingPolicy: .bufferingOldest(256))
            let failed = OSAllocatedUnfairLock(initialState: false)
            Task { @MainActor [weak self] in
                guard let self else { return }
                appChannelOpened()
                if let answer = await handleApp(first.method, first.params, id: first.id, channel: channel) {
                    channel.write(answer)
                }
                for await request in stream.stream {
                    guard !failed.withLock({ $0 }) else { break }
                    if let answer = await handleApp(request.method, request.params, id: request.id, channel: channel) {
                        channel.write(answer)
                    }
                }
                unsubscribe(channel)
                appChannelClosed()
                channel.close()
            }
            while let object = channel.readObject() {
                if case .dropped = stream.continuation.yield(WorkerRequest(object)) {
                    // A peer that outruns the actor is failed closed rather than
                    // silently dropping a control request.
                    failed.withLock { $0 = true }
                    stream.continuation.finish()
                    return
                }
            }
            // Do not drain requests that were buffered after the peer went away;
            // the actor owns teardown and will close the channel exactly once.
            failed.withLock { $0 = true }
            stream.continuation.finish()
        }
    }

    /// Serves the session the app's channel opened (`session.rd` or `session.webrtc`).
    func attach(_ request: WorkerRequest, channel: LineChannel) {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CMUX_REMOTE_HUB_URL")
        let served = AttachedScreenSession.open(
            request, channel: channel, headless: agent.headless, rdExecutable: rdExecutable,
            environment: environment, logPath: layout.log,
            onEvent: { [weak self] event, session in
                Task { @MainActor [weak self] in self?.agent.sessions.attachedEvent(session, event) }
            })
        if let served { agent.sessions.attach(served) }
    }

    @MainActor
    func appChannelOpened() {
        appChannels += 1
        agent.setRelayOnly(true)
    }

    @MainActor
    func appChannelClosed() {
        appChannels = max(0, appChannels - 1)
        if appChannels == 0 { agent.setRelayOnly(false) }
    }

    private func handleApp(_ method: String, _ params: [String: Any], id: Any?, channel: LineChannel) async -> Data? {
        switch method {
        case "host.mode":
            guard params["mode"] as? String == "relay-only" else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "mode relay-only is required")
            }
            agent.setRelayOnly(true)
            return RemoteWire.answer(id: id, result: ["mode": "relay-only"])
        case "device.identity", "device.renew":
            let identity = method == "device.renew" ? await agent.renewIdentity() : await agent.loadIdentity()
            guard let identity else { return RemoteWire.failure(id: id, code: "identity", message: "no device identity (Secure Enclave or Keychain)") }
            return RemoteWire.answer(id: id, result: ["id": identity.id, "signing_key": identity.signingKey,
                                                      "agreement_key": identity.agreementKey])
        case "device.sign":
            guard let identity = await agent.loadIdentity(), let message = (params["message"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "message (base64) is required")
            }
            // Only cmux Remote renews this device's host session: the app never signs that request.
            if message.starts(with: Data("POST\n/v1/auth/device\n".utf8)) {
                return RemoteWire.failure(id: id, code: "refused", message: "this request is cmux Remote's own")
            }
            do { return RemoteWire.answer(id: id, result: ["signature": try identity.sign(message).base64EncodedString()]) } catch {
                return RemoteWire.failure(id: id, code: "sign", message: "\(error)")
            }
        case "device.open":
            guard let identity = await agent.loadIdentity(),
                  let ciphertext = (params["ciphertext"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let key = (params["encapsulated_key"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let info = (params["info"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "ciphertext, encapsulated_key and info (base64) are required")
            }
            do {
                let plain = try identity.keys.open(ciphertext, encapsulatedKey: key, info: info)
                return RemoteWire.answer(id: id, result: ["plaintext": plain.base64EncodedString()])
            } catch {
                return RemoteWire.failure(id: id, code: "open", message: "\(error)")
            }
        case "hub.anchored":
            guard let user = params["user_id"] as? String, !user.isEmpty, let hub = params["hub_url"] as? String,
                  let url = URL(string: hub), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "user_id and an https hub_url are required")
            }
            agent.anchored(userID: user, hubURL: hub)
            return RemoteWire.answer(id: id, result: agent.status)
        case "hub.signed_out":
            agent.signedOut()
            return RemoteWire.answer(id: id, result: [:])
        case "consent":
            agent.setConsent(enabled: params["enabled"] as? Bool ?? false, view: params["view"] as? Bool ?? false,
                             full: params["full"] as? Bool ?? false)
            return RemoteWire.answer(id: id, result: [:])
        case "hub.subscribe":
            subscribe(channel)
            return RemoteWire.answer(id: id, result: agent.status)
        case "status":
            return RemoteWire.answer(id: id, result: agent.status)
        default:
            return RemoteWire.failure(id: id, code: "unknown_method", message: "unknown method \(method)")
        }
    }

    private func subscribe(_ channel: LineChannel) {
        let key = ObjectIdentifier(channel)
        subscribers[key] = channel
        agent.relay.add(key) { channel.write($0) }
    }

    private func unsubscribe(_ channel: LineChannel) {
        let key = ObjectIdentifier(channel)
        subscribers[key] = nil
        agent.relay.remove(key)
        if subscribers.isEmpty, !agent.headless {
            // `remote.headless` off: sharing ends with the app.
            agent.sessions.stop()
        }
    }
}

/// One request line, handed from a reader thread to the main actor that answers it.
struct WorkerRequest: @unchecked Sendable { // crash-allow: built by the reader thread, then read only on the main actor
    let id: Any?
    let method: String
    let params: [String: Any]

    init(_ object: [String: Any]) {
        id = object["id"]
        method = object["method"] as? String ?? ""
        params = object["params"] as? [String: Any] ?? [:]
    }
}
