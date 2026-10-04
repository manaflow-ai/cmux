public import Foundation
import os

/// A DevTools protocol session on one Chromium page. In-process CEF
/// (`CEFTab.devTools(method:params:)` and `devToolsEventStream()`) and a
/// Chromium driven over a CDP socket both provide it, so one bridge serves
/// both.
@MainActor public protocol PaneDevToolsChannel: AnyObject, Sendable {
    /// Runs `method` and returns its JSON result; throws when the page is
    /// gone or the method fails.
    func devToolsCall(_ method: String, params: [String: any Sendable]) async throws -> String
    /// The page's protocol events (method, params JSON) until it closes.
    func devToolsEvents() -> AsyncStream<PaneDevToolsEvent>
}

public nonisolated struct PaneDevToolsEvent: Equatable, Sendable {
    public var method: String
    public var params: String

    public init(method: String, params: String) {
        self.method = method
        self.params = params
    }
}

/// ``PaneHostBridge`` for Chromium through the DevTools protocol
/// (spec "Engines": `Runtime.addBinding`). No render-process code: the
/// shim's helper runs CEF without a `CefApp`, so a V8 handler or
/// `CefMessageRouter` would need a helper and ABI change; the binding needs
/// neither and works the same over a CDP socket.
///
/// - `Runtime.addBinding` puts `__cmuxPaneHost(string)` in every document
///   of the page; a call arrives as `Runtime.bindingCalled` with the
///   caller's execution context.
/// - A script added for every new document installs the WebKit-shaped API
///   (`window.webkit.messageHandlers.<name>.postMessage`) on top of it, so
///   the page does not know which engine shows it.
/// - Trust: the payload says nothing about its sender. For each request the
///   bridge asks the sender's own context for `location.href` and
///   `window === window.top`; both are unforgeable (`[LegacyUnforgeable]`),
///   so a page script cannot fake them, and a same-process iframe answers
///   false for top. Out-of-process iframes are other targets and never get
///   the binding.
/// - The reply goes back into the same context only, through
///   `__cmuxPaneHostResolve(seq, reply)`.
public final class CEFPaneHostBridge: PaneHostBridge {
    public let engine = PaneHostEngine.cef
    nonisolated public static let bindingName = "__cmuxPaneHost"
    nonisolated public static let resolveName = "__cmuxPaneHostResolve"
    /// Longest request payload accepted (the page's requests are small;
    /// git reads go through the data plane).
    nonisolated public static let maximumPayloadBytes = 1 << 20

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "pane-host.cef")
    private let channel: any PaneDevToolsChannel
    public let name: String
    private var handler: PaneHostHandler?
    private var events: Task<Void, Never>?
    private var scriptIdentifier: String?

    public init(channel: any PaneDevToolsChannel, name: String = AgentPaneRequest.handlerName) {
        self.channel = channel
        self.name = name
    }

    public func install(_ handler: @escaping PaneHostHandler) async throws {
        guard self.handler == nil else { return }
        self.handler = handler
        let stream = channel.devToolsEvents()
        // task-owner: the bridge; uninstall() cancels it and the stream ends when the page closes
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.received(event)
            }
        }
        do {
            _ = try await channel.devToolsCall("Runtime.addBinding", params: ["name": Self.bindingName])
            let added = try await channel.devToolsCall(
                "Page.addScriptToEvaluateOnNewDocument", params: ["source": Self.pageScript(name: name)])
            scriptIdentifier = CEFPaneHostWire.string(added, key: "identifier")
        } catch {
            uninstall()
            throw error
        }
    }

    public func evaluate(_ script: String) {
        let channel = channel
        // task-owner: fire and forget, as WKWebView.evaluateJavaScript without a completion handler
        Task { _ = try? await channel.devToolsCall("Runtime.evaluate", params: ["expression": script, "silent": true]) }
    }

    public func uninstall() {
        events?.cancel()
        events = nil
        guard handler != nil else { return }
        handler = nil
        let channel = channel
        let script = scriptIdentifier
        scriptIdentifier = nil
        // task-owner: best-effort teardown on a page that may already be gone
        Task {
            _ = try? await channel.devToolsCall("Runtime.removeBinding", params: ["name": Self.bindingName])
            if let script {
                _ = try? await channel.devToolsCall("Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": script])
            }
        }
    }

    // MARK: Requests

    /// Number of requests answered (tests wait on it).
    private(set) var answered = 0

    private func received(_ event: PaneDevToolsEvent) {
        guard event.method == "Runtime.bindingCalled",
              let call = CEFPaneHostWire.BindingCall(json: event.params), call.name == Self.bindingName
        else { return }
        guard call.payload.utf8.count <= Self.maximumPayloadBytes,
              let request = CEFPaneHostWire.Request(payload: call.payload)
        else {
            logger.error("pane host binding payload refused context=\(call.contextID, privacy: .public)")
            return
        }
        // task-owner: one request; its reply goes to the context that sent it
        Task { [weak self] in await self?.answer(request, context: call.contextID) }
    }

    private func answer(_ request: CEFPaneHostWire.Request, context: Int) async {
        let sender = await self.sender(context: context)
        guard let handler else { return }
        let message = PaneHostMessage(frameURL: sender?.url, isMainFrame: sender?.isTop ?? false, body: request.body)
        let reply = await handler(message)
        guard self.handler != nil else { return }
        let expression = CEFPaneHostWire.resolveExpression(seq: request.seq, reply: reply)
        _ = try? await channel.devToolsCall(
            "Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
        answered += 1
    }

    /// The sender's document URL and whether it is the top-level document,
    /// read from its own context; nil when the context is gone.
    private func sender(context: Int) async -> CEFPaneHostWire.Sender? {
        let json = try? await channel.devToolsCall("Runtime.evaluate", params: [
            "expression": "[location.href, window === window.top]",
            "contextId": context, "returnByValue": true, "silent": true,
        ])
        return json.flatMap(CEFPaneHostWire.Sender.init(evaluation:))
    }

    // MARK: Page script

    /// Installs `window.webkit.messageHandlers.<name>` over the binding.
    /// Never replaces a handler the page already has.
    static func pageScript(name: String) -> String {
        let quotedName = CEFPaneHostWire.jsonString(name)
        return """
        (() => {
          const binding = globalThis.\(bindingName);
          if (typeof binding !== "function") return;
          const pending = new Map();
          let next = 1;
          Object.defineProperty(globalThis, "\(resolveName)", {
            value: (seq, reply) => { const done = pending.get(seq); if (done) { pending.delete(seq); done(reply); } },
          });
          const handler = {
            postMessage(body) {
              return new Promise((resolve) => {
                const seq = next++;
                pending.set(seq, resolve);
                binding(JSON.stringify({ seq, body }));
              });
            },
          };
          const webkit = globalThis.webkit ?? {};
          const handlers = webkit.messageHandlers ?? {};
          if (handlers[\(quotedName)]) return;
          globalThis.webkit = { ...webkit, messageHandlers: { ...handlers, [\(quotedName)]: handler } };
        })();
        """
    }
}

/// The JSON shapes the CEF bridge reads and writes (pure, tested).
nonisolated enum CEFPaneHostWire {
    /// `Runtime.bindingCalled` params.
    nonisolated struct BindingCall: Equatable {
        var name: String
        var payload: String
        var contextID: Int

        init?(json: String) {
            guard let object = CEFPaneHostWire.object(json),
                  let name = object["name"] as? String, let payload = object["payload"] as? String,
                  let context = object["executionContextId"] as? Int
            else { return nil }
            self.name = name
            self.payload = payload
            contextID = context
        }
    }

    /// The page script's payload: `{seq, body}`.
    nonisolated struct Request {
        var seq: Int
        var body: Any

        init?(payload: String) {
            guard let object = CEFPaneHostWire.object(payload),
                  let seq = object["seq"] as? Int, seq > 0, let body = object["body"] as? [String: Any]
            else { return nil }
            self.seq = seq
            self.body = body
        }
    }

    /// The `Runtime.evaluate` result of `[location.href, window === window.top]`.
    nonisolated struct Sender: Equatable {
        var url: URL?
        var isTop: Bool

        init(url: URL?, isTop: Bool) {
            self.url = url
            self.isTop = isTop
        }

        init?(evaluation json: String) {
            guard let object = CEFPaneHostWire.object(json),
                  object["exceptionDetails"] == nil,
                  let result = object["result"] as? [String: Any],
                  let value = result["value"] as? [Any], value.count == 2,
                  let href = value[0] as? String, let isTop = value[1] as? Bool
            else { return nil }
            url = URL(string: href)
            self.isTop = isTop
        }
    }

    static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ json: String, key: String) -> String? {
        object(json)?[key] as? String
    }

    /// A JavaScript string literal (JSON is a subset of JavaScript).
    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// The reply call; a reply that is not JSON becomes a failure envelope.
    static func resolveExpression(seq: Int, reply: [String: Any]) -> String {
        let json = JSONSerialization.isValidJSONObject(reply)
            ? (try? JSONSerialization.data(withJSONObject: reply)).flatMap { String(data: $0, encoding: .utf8) }
            : nil
        let value = json ?? #"{"ok":false,"error":{"code":"native.invalid_reply","userMessage":"Invalid reply"}}"#
        return "globalThis.\(CEFPaneHostBridge.resolveName)?.(\(seq), \(value));"
    }
}
