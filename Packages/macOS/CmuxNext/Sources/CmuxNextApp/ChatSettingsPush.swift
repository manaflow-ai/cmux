import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Observation
import os

/// Pushes the config owner's effective privacy settings to the local daemon. Socket replacement
/// and settings observation are the only wakeups; no retry timer or polling is used.
@MainActor
final class ChatSettingsPush {
    private let environment: AcpmuxEnvironment
    private var watcher: ConfigFileWatcher?
    private var sendTask: Task<Void, Never>?
    private var desired: ChatSettings?
    private var sent: ChatSettings?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "chat-settings")

    init(environment: AcpmuxEnvironment) { self.environment = environment }

    /// App-lifetime observation, started at composition after the initial settings load.
    static func start(settings: SettingsController, environment: AcpmuxEnvironment?) {
        guard let environment else { return }
        let push = ChatSettingsPush(environment: environment)
        push.watchSocket()
        Task { @MainActor in
            for await value in ObservationStream({ settings.chatSettings }) {
                push.update(value)
            }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            watcher?.stop()
            sendTask?.cancel()
        }
    }

    private func watchSocket() {
        watcher = ConfigFileWatcher(url: URL(fileURLWithPath: environment.socketPath)) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sendTask?.cancel()
                self.sendTask = nil
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
        guard sendTask == nil, let desired, desired != sent,
              FileManager.default.fileExists(atPath: environment.socketPath) else { return }
        sendTask = Task { [weak self, environment] in
            let result = await AcpmuxPersonLine.request(
                environment,
                method: "_acpmux/chat_settings",
                params: [
                    "enabled": desired.enabled,
                    "discovery": desired.discovery,
                    "roots": desired.roots,
                    "managedRoots": desired.managedRoots,
                ],
                deadline: .seconds(5)
            )
            guard !Task.isCancelled else { return }
            self?.received(result?.value, value: desired)
        }
    }

    private func received(_ result: [String: Any]?, value: ChatSettings) {
        sendTask = nil
        if result?["applied"] as? Bool == true { sent = value }
        else { logger.debug("The local daemon did not accept chat settings") }
        if desired != value { send() }
    }
}
