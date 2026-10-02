import Foundation
import JavaScriptCore

/// `globalThis.__cmuxAppNative` (ABI v1). Every block runs synchronously
/// on the engine's executor (JavaScriptCore calls it from inside an
/// evaluation the actor started), so it is isolated to the engine.
extension AppEngine {
    func installNative(in context: JSContext) {
        let native = JSValue(newObjectIn: context)
        let call: @convention(block) (String, String, String, Double) -> Void = { [weak self] name, params, options, callback in
            self?.assumeIsolated { $0.nativeCall(name, params: params, options: options, callback: Int(callback)) }
        }
        let subscribe: @convention(block) (String, String) -> Double = { [weak self] stream, filter in
            self?.assumeIsolated { Double($0.nativeSubscribe(stream, filter: filter)) } ?? 0
        }
        let unsubscribe: @convention(block) (Double) -> Void = { [weak self] id in
            self?.assumeIsolated { $0.nativeUnsubscribe(Int(id)) }
        }
        let scene: @convention(block) (String, String) -> Void = { [weak self] mount, ops in
            self?.assumeIsolated { $0.nativeScene(mount, ops: ops) }
        }
        let timer: @convention(block) (Double, Bool) -> Double = { [weak self] ms, repeats in
            self?.assumeIsolated { Double($0.nativeTimer(ms: ms, repeats: repeats)) } ?? 0
        }
        let clearTimer: @convention(block) (Double) -> Void = { [weak self] id in
            self?.assumeIsolated { $0.nativeClearTimer(Int(id)) }
        }
        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.assumeIsolated { $0.configuration.output(.log(level: level, message: String(message.prefix(4096)))) }
        }
        let commandDone: @convention(block) (Double, Bool, String) -> Void = { [weak self] id, ok, json in
            self?.assumeIsolated { $0.nativeCommandDone(Int(id), ok: ok, json: json) }
        }
        native?.setObject(call, forKeyedSubscript: "call" as NSString)
        native?.setObject(subscribe, forKeyedSubscript: "subscribe" as NSString)
        native?.setObject(unsubscribe, forKeyedSubscript: "unsubscribe" as NSString)
        native?.setObject(scene, forKeyedSubscript: "scene" as NSString)
        native?.setObject(timer, forKeyedSubscript: "timer" as NSString)
        native?.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)
        native?.setObject(log, forKeyedSubscript: "log" as NSString)
        native?.setObject(commandDone, forKeyedSubscript: "commandDone" as NSString)
        context.setObject(native, forKeyedSubscript: "__cmuxAppNative" as NSString)
    }

    func nativeScene(_ mount: String, ops: String) {
        guard let json = try? AppJSON.parse(ops) else { return }
        let batch = AppSceneOp.batch(json)
        if !batch.isEmpty { configuration.output(.scene(mount: mount, ops: batch)) }
    }

    func nativeSubscribe(_ stream: String, filter: String) -> Int {
        let id = nextSubscription
        nextSubscription += 1
        subscriptions[id] = configuration.events.subscribe(stream) { [weak self] payload in
            // task-owner: one event delivery; dropped when the engine stopped
            Task { await self?.deliverEvent(id, payload: payload) }
        }
        return id
    }

    func nativeUnsubscribe(_ id: Int) {
        if let token = subscriptions.removeValue(forKey: id) { configuration.events.unsubscribe(token) }
    }

    func deliverEvent(_ id: Int, payload: AppJSON) {
        guard state == .running, subscriptions[id] != nil else { return }
        _ = enter("__cmuxAppEvent", [id, payload.jsonText])
    }

    func nativeCommandDone(_ id: Int, ok: Bool, json: String) {
        guard let continuation = commands.removeValue(forKey: id) else { return }
        let body = (try? AppJSON.parse(json)) ?? .null
        if ok {
            continuation.resume(returning: .success(body["value"] ?? .null))
        } else {
            continuation.resume(returning: .failure(AppOperationError(code: body["code"]?.stringValue ?? "command.failed",
                                                                      message: body["message"]?.stringValue ?? "command failed",
                                                                      details: body["details"])))
        }
    }
}
