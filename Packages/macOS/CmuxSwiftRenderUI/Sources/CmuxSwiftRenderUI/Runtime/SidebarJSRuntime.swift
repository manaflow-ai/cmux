import CmuxSwiftRender
import Foundation
import JavaScriptCore
import Observation

/// Hosts one sidebar program in a JavaScriptCore context and connects it to a
/// ``SceneStore``.
///
/// Lifecycle: the program runs ONCE (`start`), builds the retained scene, and
/// registers signal subscriptions on host data. After that the host only calls
/// `updateData` (per changed key) and `dispatchEvent` (taps, moves); the JS
/// side re-runs exactly the effects that depend on what changed and emits
/// minimal scene ops back. There is no per-tick re-evaluation.
///
/// Containment: the context gets no filesystem, network, or timer capability;
/// the only injected host functions are the scene-op sink, the action sink,
/// a log, and a write-only clipboard that works only during a user gesture
/// (see ``clipboardWriteByteLimit``). A watchdog (`JSContextGroupSetExecutionTimeLimit`) terminates
/// any single evaluation that runs longer than ``executionTimeLimit`` seconds,
/// so a hostile or buggy program degrades to an error state instead of
/// hanging the process.
@MainActor
@Observable
public final class SidebarJSRuntime {
    public let store = SceneStore()
    /// Set when the program threw (load, data update, or event). The host view
    /// shows this instead of the scene.
    public private(set) var errorMessage: String?
    /// Runs captured commands (cmux/openURL/log) on the host command surface.
    @ObservationIgnored public var dispatch: SidebarActionDispatch = .noop

    @ObservationIgnored private var context: JSContext?
    /// Nesting depth of user-gesture dispatches currently on the stack.
    /// `clipboard.write` succeeds only while this is above zero, so load,
    /// data updates, and callbacks deferred past the gesture cannot write.
    @ObservationIgnored private var userActivationDepth = 0
    nonisolated static let executionTimeLimit = 0.25
    /// Largest `clipboard.write` payload accepted, in UTF-8 bytes.
    nonisolated static let clipboardWriteByteLimit = 64 * 1024
    /// Events that count as a user gesture: clicks (including context-menu
    /// items, which dispatch as taps) and double-clicks. Text-field `submit`
    /// does not: it also fires on focus loss, and an autofocused field can
    /// receive a Return the user meant for the terminal. Drag feedback,
    /// reorder moves, and per-keystroke edits do not count either.
    nonisolated static let userActivationEvents: Set<String> = ["tap", "doubletap"]

    public init() {}

    /// Loads the prelude and runs `source`. Returns false (and sets
    /// ``errorMessage``) when the program fails to produce a scene root.
    @discardableResult
    public func start(source: String) -> Bool {
        errorMessage = nil
        guard let context = JSContext() else {
            errorMessage = "JavaScriptCore context could not be created."
            return false
        }
        self.context = context
        installWatchdog(context)

        // Exceptions surface synchronously during evaluate/call, and every
        // entry point of this class is main-actor, so the handler runs on the
        // main actor; assumeIsolated keeps the errorMessage write synchronous
        // (the start() error checks below rely on that).
        context.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? "unknown error"
            let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
            MainActor.assumeIsolated {
                self?.errorMessage = line > 0 ? "line \(line): \(text)" : text
            }
        }

        let applyOps: @convention(block) (String) -> Void = { [weak self] json in
            MainActor.assumeIsolated {
                self?.store.apply(opsJSON: json)
            }
        }
        let action: @convention(block) (String) -> Void = { [weak self] json in
            MainActor.assumeIsolated {
                self?.runAction(json: json)
            }
        }
        let log: @convention(block) (String) -> Void = { message in
            Self.debugLog(message)
        }
        let clipboardWrite: @convention(block) (String) -> Bool = { [weak self] text in
            MainActor.assumeIsolated {
                self?.writeClipboard(text) ?? false
            }
        }
        context.setObject(applyOps, forKeyedSubscript: "__host_applyOps" as NSString)
        context.setObject(action, forKeyedSubscript: "__host_action" as NSString)
        context.setObject(log, forKeyedSubscript: "__host_log" as NSString)
        context.setObject(clipboardWrite, forKeyedSubscript: "__host_clipboardWrite" as NSString)

        guard let preludeURL = Bundle.module.url(forResource: "SidebarRuntime", withExtension: "js"),
              let prelude = try? String(contentsOf: preludeURL, encoding: .utf8) else {
            errorMessage = "Sidebar runtime prelude is missing from the app bundle."
            return false
        }
        context.evaluateScript(prelude, withSourceURL: URL(fileURLWithPath: "SidebarRuntime.js"))
        if errorMessage != nil { return false }
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: "sidebar.js"))
        if errorMessage != nil { return false }
        if store.rootId == nil, errorMessage == nil {
            errorMessage = "The sidebar program did not call sidebar(fn) with a view."
        }
        return errorMessage == nil
    }

    /// Pushes one changed data key into the runtime. JSON-encodes `value`
    /// through the plain-JSON reading of ``SwiftValue``.
    public func updateData(key: String, value: SwiftValue) {
        guard let context else { return }
        guard let json = Self.jsonString(value) else { return }
        context.objectForKeyedSubscript("__setData")?
            .call(withArguments: [key, json])
    }

    /// Delivers a UI event (tap, move) to the node's JS handler.
    ///
    /// For ``userActivationEvents`` the handler runs inside a user-activation
    /// scope that lasts exactly as long as this synchronous call, which is the
    /// only time `clipboard.write` is honored.
    public func dispatchEvent(nodeId: String, event: String, payload: [String: Any] = [:]) {
        guard let context else { return }
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let activates = Self.userActivationEvents.contains(event)
        if activates { userActivationDepth += 1 }
        defer { if activates { userActivationDepth -= 1 } }
        context.objectForKeyedSubscript("__dispatch")?
            .call(withArguments: [nodeId, event, json])
    }

    // MARK: - Clipboard

    /// Backs `clipboard.write(text)`: writes plain text through the host's
    /// clipboard writer when a user gesture is being dispatched, the text fits
    /// ``clipboardWriteByteLimit``, and the host offers a clipboard.
    ///
    /// Otherwise nothing is written; the reason goes to the `log` channel and
    /// the JS call returns `false`. There is deliberately no read counterpart.
    private func writeClipboard(_ text: String) -> Bool {
        guard userActivationDepth > 0 else {
            return rejectClipboardWrite(
                "only allowed while handling a click or menu action, not during load, data updates, text-field submits, or deferred callbacks"
            )
        }
        let byteCount = text.utf8.count
        guard byteCount <= Self.clipboardWriteByteLimit else {
            return rejectClipboardWrite(
                "text is \(byteCount) bytes; the limit is \(Self.clipboardWriteByteLimit) bytes"
            )
        }
        guard let writer = dispatch.writeClipboard else {
            return rejectClipboardWrite("this sidebar host has no clipboard access")
        }
        writer(text)
        return true
    }

    private func rejectClipboardWrite(_ reason: String) -> Bool {
        let message = "clipboard.write rejected: \(reason)"
        Self.debugLog(message)
        enqueue(ButtonAction(commands: [.log(message)]))
        return false
    }

    nonisolated private static func debugLog(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("sidebar-js: \(message)\n".utf8))
        #endif
    }

    // MARK: - Actions

    private func runAction(json: String) {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              let kind = object["kind"] as? String else { return }
        let action: ButtonAction
        switch kind {
        case "cmux":
            guard let method = object["method"] as? String else { return }
            let params = (object["params"] as? [String: String]) ?? [:]
            action = ButtonAction(commands: [.cmux(method: method, params: params)])
        case "openURL":
            guard let url = object["url"] as? String else { return }
            action = ButtonAction(commands: [.openURL(url)])
        case "log":
            guard let message = object["message"] as? String else { return }
            action = ButtonAction(commands: [.log(message)])
        default:
            return
        }
        enqueue(action)
    }

    private func enqueue(_ action: ButtonAction) {
        // Deferred one runloop turn ON PURPOSE: the JS handler applies its
        // optimistic scene updates synchronously before calling cmux(...),
        // and a heavy host command (workspace.select swaps terminals) running
        // inside the same turn would block that paint - rapid click-click-
        // click then feels laggy even though the state already flipped.
        // Ordering between queued actions is preserved.
        let dispatch = self.dispatch
        DispatchQueue.main.async {
            dispatch.run(action)
        }
    }

    // MARK: - Watchdog

    private func installWatchdog(_ context: JSContext) {
        JSWatchdog.install(on: context, seconds: Self.executionTimeLimit)
    }

    // MARK: - Validation

    /// Validates a JS sidebar program without a host: runs it against `state`
    /// in a throwaway context with no-op sinks and returns the first error, or
    /// nil when it produced a scene root. Thread-free (a fresh JSContext is
    /// usable on any thread), so the socket-CLI validator can call it directly.
    nonisolated static func validate(source: String, state: [String: SwiftValue]) -> String? {
        guard let context = JSContext() else { return "JavaScriptCore context could not be created." }
        JSWatchdog.install(on: context, seconds: executionTimeLimit)

        final class ErrorBox: @unchecked Sendable { var message: String?; var sawRoot = false }
        let box = ErrorBox()
        context.exceptionHandler = { _, exception in
            let text = exception?.toString() ?? "unknown error"
            let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
            if box.message == nil {
                box.message = line > 0 ? "line \(line): \(text)" : text
            }
        }
        let applyOps: @convention(block) (String) -> Void = { json in
            // JSON.stringify output is unspaced, so the root op appears
            // exactly as {"op":"root",...}.
            if json.contains("\"op\":\"root\"") { box.sawRoot = true }
        }
        let noop: @convention(block) (String) -> Void = { _ in }
        // Validation dispatches no gestures, so every clipboard write is
        // rejected, exactly as it would be during a real load.
        let rejectClipboard: @convention(block) (String) -> Bool = { _ in false }
        context.setObject(applyOps, forKeyedSubscript: "__host_applyOps" as NSString)
        context.setObject(noop, forKeyedSubscript: "__host_action" as NSString)
        context.setObject(noop, forKeyedSubscript: "__host_log" as NSString)
        context.setObject(rejectClipboard, forKeyedSubscript: "__host_clipboardWrite" as NSString)

        guard let preludeURL = Bundle.module.url(forResource: "SidebarRuntime", withExtension: "js"),
              let prelude = try? String(contentsOf: preludeURL, encoding: .utf8) else {
            return "Sidebar runtime prelude is missing from the app bundle."
        }
        context.evaluateScript(prelude, withSourceURL: URL(fileURLWithPath: "SidebarRuntime.js"))
        if let message = box.message { return message }
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: "sidebar.js"))
        if let message = box.message { return message }
        for (key, value) in state {
            guard let json = jsonString(value) else { continue }
            context.objectForKeyedSubscript("__setData")?.call(withArguments: [key, json])
            if let message = box.message { return message }
        }
        if !box.sawRoot {
            return "The sidebar program did not call sidebar(fn) with a view."
        }
        return nil
    }

    // MARK: - SwiftValue → JSON

    /// The plain-JSON reading of a ``SwiftValue`` (its synthesized Codable form
    /// is tagged and unusable for JS).
    nonisolated static func jsonString(_ value: SwiftValue) -> String? {
        let object = jsonObject(value)
        guard JSONSerialization.isValidJSONObject([object]) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func jsonObject(_ value: SwiftValue) -> Any {
        switch value {
        case let .int(v): return v
        case let .double(v): return v.isFinite ? v : 0
        case let .string(v): return v
        case let .bool(v): return v
        case let .range(lower, upper, inclusive):
            return ["lower": lower, "upper": upper, "inclusive": inclusive]
        case let .array(values): return values.map { jsonObject($0) }
        case let .object(fields): return fields.mapValues { jsonObject($0) }
        case .null: return NSNull()
        }
    }
}
