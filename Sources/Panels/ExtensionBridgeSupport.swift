import AppKit
import Foundation
import WebKit

struct ExtensionBridgeMessage {
    let id: Any
    let method: String
    let params: [String: Any]

    init?(body: [String: Any]) {
        guard let id = body["id"] else { return nil }
        guard let method = (body["method"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !method.isEmpty else { return nil }
        self.id = id
        self.method = method
        self.params = body["params"] as? [String: Any] ?? [:]
    }
}

final class ExtensionBridgeMessageHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (ExtensionBridgeMessage, WKWebView?) -> Void

    init(onMessage: @escaping @MainActor (ExtensionBridgeMessage, WKWebView?) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame else { return }
        guard let body = message.body as? [String: Any],
              let bridgeMessage = ExtensionBridgeMessage(body: body) else {
            return
        }
        Task { @MainActor in
            onMessage(bridgeMessage, message.webView)
        }
    }
}

final class ExtensionWebView: WKWebView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

enum ExtensionBridgeCodec {
    static func javaScriptLiteral(for object: Any) -> String {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: []),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return encodeJSONFragment(object) ?? "null"
    }

    static func bridgeOK(_ result: Any) -> [String: Any] {
        [
            "ok": true,
            "result": result
        ]
    }

    static func bridgeError(code: String, message: String, data: Any? = nil) -> [String: Any] {
        [
            "ok": false,
            "error": [
                "code": code,
                "message": message,
                "data": data ?? NSNull()
            ]
        ]
    }

    static func encodeJSONFragment(_ value: Any) -> String? {
        let wrapped = [value]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: []),
              let string = String(data: data, encoding: .utf8),
              string.count >= 2 else {
            return nil
        }
        return String(string.dropFirst().dropLast())
    }

    static func decodeJSONFragment(_ value: String?) -> Any? {
        guard let value,
              let data = "[\(value)]".data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        return decoded.first ?? NSNull()
    }
}

enum ExtensionBridgeJavaScript {
    static func bootstrapScript(context: [String: Any]) -> String {
        let contextLiteral = ExtensionBridgeCodec.javaScriptLiteral(for: context)
        return """
        (() => {
          const initialContext = \(contextLiteral);
          if (window.__cmuxExtensionBridgeInstalled) {
            if (window.__cmuxExtensionBridgeUpdateContext) {
              window.__cmuxExtensionBridgeUpdateContext(initialContext);
            }
            return;
          }
          window.__cmuxExtensionBridgeInstalled = true;
          let nextRequestId = 1;
          const pending = new Map();
          const context = Object.assign({}, initialContext || {});
          const eventHandlers = new Map();

          const normalizeWorkspace = (params) => {
            const next = Object.assign({}, params || {});
            if (next.workspace && !next.workspace_id) next.workspace_id = next.workspace;
            delete next.workspace;
            if (!next.workspace_id && context.workspaceId) next.workspace_id = context.workspaceId;
            return next;
          };

          const normalizeSurface = (params) => {
            const next = normalizeWorkspace(params);
            if (next.surface && !next.surface_id) next.surface_id = next.surface;
            delete next.surface;
            return next;
          };

          const normalizePane = (params) => {
            const next = normalizeSurface(params);
            if (next.pane && !next.pane_id) next.pane_id = next.pane;
            delete next.pane;
            if (!next.pane_id && context.paneId) next.pane_id = context.paneId;
            return next;
          };

          const rpc = (method, params = {}) => new Promise((resolve, reject) => {
            const id = String(nextRequestId++);
            pending.set(id, { resolve, reject });
            window.webkit.messageHandlers.cmuxExtension.postMessage({ id, method, params });
          });

          window.__cmuxExtensionBridgeReceive = (message) => {
            const id = String(message && message.id);
            const entry = pending.get(id);
            if (!entry) return;
            pending.delete(id);
            if (message && message.ok) {
              entry.resolve(message.result);
              return;
            }
            const errorPayload = (message && message.error) || {};
            const error = new Error(errorPayload.message || "cmux bridge request failed");
            error.code = errorPayload.code || "bridge_error";
            error.data = errorPayload.data;
            entry.reject(error);
          };

          window.__cmuxExtensionBridgeUpdateContext = (next) => {
            Object.assign(context, next || {});
          };

          window.__cmuxExtensionBridgeDispatchEvent = (subscriptionId, event) => {
            const entry = eventHandlers.get(String(subscriptionId));
            if (!entry) return;
            entry.handler(event);
          };

          const cmux = {
            api: Object.freeze({ version: 1 }),
            get context() {
              return Object.freeze(Object.assign({}, context));
            },
            rpc,
            tree(params = {}) {
              return rpc("system.tree", normalizeWorkspace(params));
            },
            workspaces: Object.freeze({
              list(params = {}) {
                return rpc("workspace.list", normalizeWorkspace(params));
              },
              current(params = {}) {
                return rpc("workspace.current", normalizeWorkspace(params));
              }
            }),
            panes: Object.freeze({
              list(params = {}) {
                return rpc("pane.list", normalizeWorkspace(params));
              },
              surfaces(params = {}) {
                return rpc("pane.surfaces", normalizePane(params));
              }
            }),
            surfaces: Object.freeze({
              list(params = {}) {
                return rpc("surface.list", normalizeWorkspace(params));
              },
              current(params = {}) {
                return rpc("surface.current", normalizeWorkspace(params));
              },
              focus(params = {}) {
                return rpc("surface.focus", normalizeSurface(params));
              }
            }),
            send(params = {}) {
              return rpc("surface.send_text", normalizeSurface(params));
            },
            sendKey(params = {}) {
              return rpc("surface.send_key", normalizeSurface(params));
            },
            newPane(params = {}) {
              const next = normalizeSurface(params);
              if (!next.surface_id && context.surfaceId) next.surface_id = context.surfaceId;
              if (!next.direction) next.direction = "right";
              return rpc("pane.create", next);
            },
            newSurface(params = {}) {
              return rpc("surface.create", normalizePane(params));
            },
            events: Object.freeze({
              subscribe(params = {}, handler) {
                if (typeof params === "function") {
                  handler = params;
                  params = {};
                }
                return rpc("extension.events.subscribe", params || {}).then((subscription) => {
                  const id = String(subscription.subscription_id);
                  if (typeof handler === "function") {
                    eventHandlers.set(id, { handler });
                    for (const event of subscription.replay || []) {
                      Promise.resolve().then(() => handler(event));
                    }
                  }
                  return Object.freeze({
                    id,
                    ack: subscription.ack,
                    replay: subscription.replay || [],
                    unsubscribe() {
                      eventHandlers.delete(id);
                      return rpc("extension.events.unsubscribe", { subscription_id: id });
                    }
                  });
                });
              }
            }),
            kv: Object.freeze({
              get(key) {
                return rpc("extension.kv.get", { key }).then((result) => result.value);
              },
              set(key, value) {
                return rpc("extension.kv.set", { key, value });
              },
              remove(key) {
                return rpc("extension.kv.remove", { key });
              },
              keys() {
                return rpc("extension.kv.keys", {});
              }
            })
          };

          Object.defineProperty(window, "cmux", {
            value: Object.freeze(cmux),
            configurable: false,
            enumerable: true,
            writable: false
          });
        })();
        """
    }
}
