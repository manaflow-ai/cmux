import Foundation

extension ChromiumPageHostBridge {
    // MARK: DevTools calls

    /// The DevTools calls that set the page up, in order: ``setUp(documentScripts:)`` runs them
    /// before the first document loads. The Runtime domain stays on until that document commits
    /// (``documentCommitted()``).
    public static func setupCalls(handlers: [String], documentScripts: [String]) -> [(String, [String: any Sendable])] {
        var calls: [(String, [String: any Sendable])] = [
            // New-document scripts run only while the Page domain is on, and bindings reach worlds
            // made later only while the Runtime domain is on.
            ("Page.enable", [:]),
            ("Runtime.enable", [:]),
            bindingCall,
            ("Page.addScriptToEvaluateOnNewDocument", ["source": pageScript(handlers: handlers), "runImmediately": true]),
        ]
        for source in documentScripts {
            calls.append(("Page.addScriptToEvaluateOnNewDocument", ["source": source, "runImmediately": true]))
        }
        return calls
    }

    nonisolated static let bindingCall: (String, [String: any Sendable]) = ("Runtime.addBinding", ["name": bindingName])

    /// The calls that turn the Runtime domain on for a navigation: on, then the binding again
    /// (`Runtime.disable` dropped the session's bindings; without it the new document never gets
    /// one, measured).
    nonisolated static let enableCalls: [(String, [String: any Sendable])] = [("Runtime.enable", [:]), bindingCall]

    /// The calls for a committed main-frame document: the Runtime domain off (when it is on), then
    /// the binding again. The binding call puts the binding in the document's main world whatever
    /// the domain's state: a navigation the page started itself (``navigate(_:)`` did not turn the
    /// domain on for it) gets it this way, a few milliseconds after its start, and the page script
    /// keeps the page's messages until then. Where the binding is there already, it is a no-op.
    nonisolated static func commitCalls(runtimeEnabled: Bool) -> [(String, [String: any Sendable])] {
        var calls: [(String, [String: any Sendable])] = []
        if runtimeEnabled { calls.append(("Runtime.disable", [:])) }
        calls.append(bindingCall)
        return calls
    }

    // MARK: Page script

    /// Installs `window.webkit.messageHandlers.<name>` for ``PageHostTrust/handlerName`` (with
    /// replies) and each of `handlers` (without) over the binding. Messages posted before the
    /// binding exists wait in the page and go out once it appears (the page looks every 5 ms, for
    /// 2 s after each send that found none). A call past
    /// ``maximumPayloadBytes`` is never sent (``receive(devToolsMessage:)`` drops it unanswered):
    /// it settles at once with a `cmux.protocol.too_large` error envelope.
    public static func pageScript(handlers: [String]) -> String {
        let names = ([PageHostTrust.handlerName] + handlers).map(ChromiumPageHostWire.jsonString).joined(separator: ", ")
        let replying = ChromiumPageHostWire.jsonString(PageHostTrust.handlerName)
        return """
        (() => {
          if (globalThis.__cmuxPageHostInstalled) return;
          Object.defineProperty(globalThis, "__cmuxPageHostInstalled", { value: true });
          const pending = new Map();
          const queue = [];
          let next = 1;
          let retries = 0;
          const limit = \(maximumPayloadBytes);
          // UTF-8 bytes, counted only when the text could be past the limit.
          const tooLarge = (text) => {
            if (text.length > limit) return true;
            if (text.length * 3 <= limit) return false;
            let bytes = 0;
            for (let at = 0; at < text.length; at += 1) {
              const code = text.charCodeAt(at);
              bytes += code < 0x80 ? 1 : code < 0x800 || (code >= 0xd800 && code < 0xe000) ? 2 : 3;
            }
            return bytes > limit;
          };
          const flush = () => {
            const binding = globalThis.\(bindingName);
            if (typeof binding !== "function") return false;
            while (queue.length) binding(queue.shift());
            return true;
          };
          let retrying = false;
          const retry = () => {
            retrying = false;
            if (flush() || ++retries >= 400) return;
            retrying = true;
            setTimeout(retry, 5);
          };
          // Every send that finds no binding and no retry pending starts the retries again, also
          // after 400 ran out with messages still queued (they wait for the binding).
          const send = (text) => {
            queue.push(text);
            if (flush() || retrying) return;
            retries = 0;
            retrying = true;
            setTimeout(retry, 5);
          };
          Object.defineProperty(globalThis, "\(resolveName)", {
            value: (seq, reply) => { const done = pending.get(seq); if (done) { pending.delete(seq); done(reply); } },
          });
          const handlers = {};
          for (const name of [\(names)]) {
            handlers[name] = {
              postMessage(body) {
                if (name !== \(replying)) { send(JSON.stringify({ name, body })); return undefined; }
                return new Promise((resolve) => {
                  const seq = next++;
                  const text = JSON.stringify({ name, seq, body });
                  if (tooLarge(text)) {
                    resolve({ t: "err", id: body?.id, code: "cmux.protocol.too_large", message: "The request is too large to send." });
                    return;
                  }
                  pending.set(seq, resolve);
                  send(text);
                });
              },
            };
          }
          const webkit = globalThis.webkit ?? {};
          globalThis.webkit = { ...webkit, messageHandlers: { ...(webkit.messageHandlers ?? {}), ...handlers } };
        })();
        """
    }
}
