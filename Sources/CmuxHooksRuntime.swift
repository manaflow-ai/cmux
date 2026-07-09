import CmuxHooks
import CmuxSettings
import CmuxTerminal
import Foundation
#if DEBUG
import CMUXDebugLog
#endif

final class CmuxHooksRuntime {
    static let shared = CmuxHooksRuntime()

    let configState: @Sendable () -> CmuxHooksConfigState
    let spawnHookGate: SpawnHookGate

    private let cache: CmuxHooksRuntimeConfigCache
    private let dispatcher: EventHookDispatcher

    private init() {
        let fileURL = CmuxConfigLocation().userConfigFile
        let loader = CmuxHooksConfigLoader()
        let cache = CmuxHooksRuntimeConfigCache(fileURL: fileURL, loader: loader)
        let provider: @Sendable () -> CmuxHooksConfigState = {
            cache.configState()
        }
        let runner = HookProcessRunner()
        let logger: @Sendable (String) -> Void = { message in
#if DEBUG
            logDebugEvent("hooks \(message)")
#endif
        }
        let gate = SpawnHookGate(configState: provider, runner: runner, log: logger)
        self.cache = cache
        self.configState = provider
        self.spawnHookGate = gate
        self.dispatcher = EventHookDispatcher(configState: provider, runner: runner, log: logger)
    }

    func makeEventSink() -> (_ eventName: String, _ envelope: [String: Any]) -> Void {
        { [cache, dispatcher] eventName, envelope in
            guard !eventName.hasPrefix("hook.") else { return }
            guard cache.subscribedEventNames().contains(eventName) else { return }
            guard JSONSerialization.isValidJSONObject(envelope),
                  let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else {
#if DEBUG
                logDebugEvent("hooks event encode failed name=\(eventName)")
#endif
                return
            }
            Task {
                await dispatcher.dispatch(eventName: eventName, envelopeJSON: data)
            }
        }
    }
}
