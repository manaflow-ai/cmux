import CmuxHooks
import CmuxSettings
import CmuxTerminal
import Foundation
#if DEBUG
import CMUXDebugLog
#endif

final class CmuxHooksRuntime {
    static let shared = CmuxHooksRuntime()

    let spawnGateBridge: TerminalSurfaceSpawnGateBridge
    private let dispatcher: EventHookDispatcher

    private init() {
        let fileURL = CmuxConfigLocation().userConfigFile
        let loader = CmuxHooksConfigLoader()
        let provider: @Sendable () -> CmuxHooksConfigState = {
            loader.load(fileURL: fileURL)
        }
        let runner = HookProcessRunner()
        let logger: @Sendable (String) -> Void = { message in
#if DEBUG
            logDebugEvent("hooks \(message)")
#endif
        }
        let gate = SpawnHookGate(configState: provider, runner: runner, log: logger)
        self.dispatcher = EventHookDispatcher(configState: provider, runner: runner, log: logger)
        self.spawnGateBridge = TerminalSurfaceSpawnGateBridge(
            configState: provider,
            gate: gate
        )
    }

    func makeEventSink() -> (_ eventName: String, _ envelope: [String: Any]) -> Void {
        { [dispatcher] eventName, envelope in
            guard !eventName.hasPrefix("hook.") else { return }
            Task {
                let names = await dispatcher.subscribedEventNames()
                guard names.contains(eventName) else { return }
                guard JSONSerialization.isValidJSONObject(envelope),
                      let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else {
#if DEBUG
                    logDebugEvent("hooks event encode failed name=\(eventName)")
#endif
                    return
                }
                await dispatcher.dispatch(eventName: eventName, envelopeJSON: data)
            }
        }
    }
}
