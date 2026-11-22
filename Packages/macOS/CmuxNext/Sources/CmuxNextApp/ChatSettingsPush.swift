import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Observation
import os

/// Pushes the config owner's effective privacy settings to the local daemon. Socket replacement
/// and settings observation are the only wakeups; no retry timer or polling is used.
@MainActor
final class ChatSettingsPush {
    private let socket: String
    private var watcher: ConfigFileWatcher?
    private var connection: AgentActivityLineConnection?
    private var desired: ChatSettings?
    private var sent: ChatSettings?
    private var loggedUnsupported = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "chat-settings")

    init(socketPath: String) { socket = socketPath }

    /// App-lifetime observation, started at composition after the initial settings load.
    static func start(settings: SettingsController, environment: AcpmuxEnvironment?) {
        guard let environment else { return }
        let push = ChatSettingsPush(socketPath: environment.socketPath)
        push.watchSocket()
        Task { @MainActor in
            for await value in Observations({ settings.chatSettings }) {
                push.update(value)
            }
        }
    }

    isolated deinit {
        watcher?.stop()
        connection?.cancel()
    }

    private func watchSocket() {
        watcher = ConfigFileWatcher(url: URL(fileURLWithPath: socket)) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.connection?.cancel()
                self.connection = nil
                self.sent = nil
                self.send()
            }
        }
        watcher?.start()
    }

    private func update(_ value: ChatSettings) {
        guard value != desired else { return }
        desired = value
        // Serialize requests: a newer value waits for the in-flight reply, so it cannot be
        // overwritten by an older connection arriving later at the daemon.
        send()
    }

    private func send() {
        guard connection == nil, let desired, desired != sent,
              FileManager.default.fileExists(atPath: socket) else { return }
        let current = AgentActivityLineConnection(path: socket)
        connection = current
        current.start(send: desired.request, onLine: { [weak self] line in
            Task { @MainActor in self?.received(line, from: current, value: desired) }
        }, onClose: { [weak self] in
            Task { @MainActor in
                guard let self, self.connection === current else { return }
                self.connection = nil
                if self.desired != desired { self.send() }
                // A restarted daemon replaces its socket. Its vnode event retries the latest
                // settings; a settings change also triggers a new attempt.
            }
        })
    }

    private func received(_ line: Data, from current: AgentActivityLineConnection, value: ChatSettings) {
        guard connection === current, let message = try? JSONValue.parse(line), message["id"]?.doubleValue == 2 else { return }
        let unsupported = message["error"]?["code"]?.doubleValue == -32601
        if unsupported, !loggedUnsupported {
            logger.debug("The local daemon does not support chat settings yet")
            loggedUnsupported = true
        }
        let applied = message["result"]?["applied"]?.boolValue == true
        current.cancel()
        connection = nil
        // Treat an old daemon's refusal as settled; do not spin or surface an alert.
        if applied || unsupported { sent = value }
        if desired != value { send() }
    }
}
