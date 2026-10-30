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
/// serves the app's channels, which the host splices through.
@MainActor
public final class ScreenSharingWorker: NSObject, NSApplicationDelegate {
    let layout: RemoteHostLayout
    let agent: DeviceAgent
    private let control = LineChannel(read: STDIN_FILENO, write: STDOUT_FILENO)
    private var statusQueued = false
    /// The app's subscriptions, by channel; `perform` asks go to the newest.
    private var subscribers: [ObjectIdentifier: LineChannel] = [:]
    private var subscriberOrder: [ObjectIdentifier] = []
    private var performs: [Int: CheckedContinuation<AppAnswer?, Never>] = [:]
    private var nextPerform = 1

    public init(layout: RemoteHostLayout, stateDirectory: String, keychainScope: String, headless: Bool) {
        self.layout = layout
        agent = DeviceAgent(keychainScope: keychainScope, statePath: stateDirectory + "/screen-sharing.json", headless: headless)
        super.init()
        agent.changed = { [weak self] in self?.queueStatus() }
        agent.delegateToApp = { [weak self] action, params in await self?.perform(action, params) }
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

    private func handle(_ method: String, _ params: [String: Any], id: Any?) async -> Data {
        switch method {
        case "status":
            return RemoteWire.answer(id: id, result: agent.status)
        case "share":
            guard let on = params["on"] as? Bool else { return RemoteWire.failure(id: id, code: "bad_request", message: "on must be true or false") }
            switch await agent.share(on) {
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
            while let object = channel.readObject() {
                let request = WorkerRequest(object)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let answer = await handleApp(request.method, request.params, id: request.id, channel: channel) { channel.write(answer) }
                }
            }
            Task { @MainActor [weak self] in self?.unsubscribe(channel) }
            channel.close()
        }
    }

    private func handleApp(_ method: String, _ params: [String: Any], id: Any?, channel: LineChannel) async -> Data? {
        switch method {
        case "device.identity", "device.renew":
            let identity = method == "device.renew" ? await agent.renewIdentity() : await agent.loadIdentity()
            guard let identity else { return RemoteWire.failure(id: id, code: "identity", message: "no device identity (Secure Enclave or Keychain)") }
            return RemoteWire.answer(id: id, result: ["id": identity.id, "signing_key": identity.signingKey,
                                                      "agreement_key": identity.agreementKey])
        case "device.sign":
            guard let identity = await agent.loadIdentity(), let message = (params["message"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "message (base64) is required")
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
        case "perform.done":
            if let ask = params["id"] as? Int, let waiting = performs.removeValue(forKey: ask) {
                waiting.resume(returning: AppAnswer(ok: params["ok"] as? Bool == true, message: params["message"] as? String))
            }
            return nil
        case "status":
            return RemoteWire.answer(id: id, result: agent.status)
        default:
            return RemoteWire.failure(id: id, code: "unknown_method", message: "unknown method \(method)")
        }
    }

    private func subscribe(_ channel: LineChannel) {
        let key = ObjectIdentifier(channel)
        subscribers[key] = channel
        subscriberOrder.append(key)
        agent.relay.add(key) { channel.write($0) }
    }

    private func unsubscribe(_ channel: LineChannel) {
        let key = ObjectIdentifier(channel)
        subscribers[key] = nil
        subscriberOrder.removeAll { $0 == key }
        agent.relay.remove(key)
        if subscribers.isEmpty, !agent.headless {
            // `remote.headless` off: sharing ends with the app.
            agent.sessions.stop()
        }
    }

    /// Asks the newest subscribed app to run `action` (it holds the full session); nil when none is subscribed.
    private func perform(_ action: String, _ params: [String: Any]) async -> [String: Any]? {
        guard let answer = await ask(action, params) else { return nil }
        var fields: [String: Any] = ["ok": answer.ok]
        if let message = answer.message { fields["message"] = message }
        return fields
    }

    private func ask(_ action: String, _ params: [String: Any]) async -> AppAnswer? {
        guard let key = subscriberOrder.last, let channel = subscribers[key] else { return nil }
        let ask = nextPerform
        nextPerform += 1
        return await withCheckedContinuation { (continuation: CheckedContinuation<AppAnswer?, Never>) in
            performs[ask] = continuation
            if !channel.write(RemoteWire.event("perform", ["id": ask, "action": action, "params": params as Any])) {
                performs.removeValue(forKey: ask)?.resume(returning: nil)
            }
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

/// A subscribed app's answer to a `perform` ask.
struct AppAnswer: Sendable {
    var ok: Bool
    var message: String?
}
