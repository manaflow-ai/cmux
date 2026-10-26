public import Foundation

/// One document-start script the app installs in every Chromium renderer once (fork API 29,
/// ``ChromiumPageHostBridge/rendererScripts(handlers:documentScripts:world:channel:)``).
public nonisolated struct ChromiumPageRendererScript: Sendable, Equatable {
    /// The isolated world it runs in; "" for the page's own world.
    public var world: String
    public var source: String
    /// Every frame; false for the main frame only.
    public var allFrames: Bool

    public init(world: String, source: String, allFrames: Bool) {
        self.world = world
        self.source = source
        self.allFrames = allFrames
    }
}

/// The page-side half of ``ChromiumPageHostBridge``: `window.webkit.messageHandlers.<name>` for
/// ``PageHostTrust/handlerName`` (with replies) and the fire-and-forget handlers, over one transport.
extension ChromiumPageHostBridge {
    /// The DevTools path's script for every new document: the API over the `__cmuxPageHost`
    /// binding. Messages posted before the binding exists wait in the page and go out once it
    /// appears; when it never does, their calls fail instead of waiting for ever.
    ///
    /// - Parameter handlers: The fire-and-forget handler names.
    /// - Returns: The script.
    nonisolated public static func pageScript(handlers: [String]) -> String {
        api(handlers: handlers, transport: """
          const queue = [];
          let retries = 0;
          let waiting = false;
          const flush = () => {
            const binding = globalThis.\(bindingName);
            if (typeof binding !== "function") return false;
            while (queue.length) binding(queue.shift());
            return true;
          };
          const retry = () => {
            if (flush()) { waiting = false; return; }
            if (++retries > 400) { waiting = false; while (queue.length) failText(queue.shift()); return; }
            setTimeout(retry, 5);
          };
          const send = (text) => {
            queue.push(text);
            if (!flush() && !waiting) { waiting = true; retries = 0; retry(); }
          };
        """)
    }

    /// The renderer path's scripts, installed once for every browser before Chromium starts. Both
    /// return outside the main frame of a `cmux-page:` document, so a web page never gets them.
    ///
    /// - The page world gets the API, then `documentScripts`, before any script of the page runs.
    ///   A post goes to the channel world as a ``postEventName`` event whose detail is the message
    ///   text (Blink hands a `CustomEvent` detail across worlds,
    ///   third_party/blink/renderer/core/events/custom_event.cc).
    /// - The channel world posts it on `channel` (`cmuxPost`) inside a ``ChromiumPageHostWire/ChannelPost``
    ///   with the document's own `location.href`, which no page script can change in that world.
    ///   Without `cmuxPost` the call fails at once (``unavailableEventName``).
    ///
    /// - Parameters:
    ///   - handlers: Handler names every cmux page gets at document start; a page adds its own at
    ///     commit (``rebind()``).
    ///   - documentScripts: Scripts every cmux page runs at document start
    ///     (``PageChromiumDocumentScripts/shared``), each in its own block.
    ///   - world: The isolated world `channel` lives in.
    ///   - channel: The page channel the fork delivers as a page message.
    /// - Returns: The channel world's script, then the page world's.
    nonisolated public static func rendererScripts(handlers: [String], documentScripts: [String], world: String,
                                                   channel: String) -> [ChromiumPageRendererScript] {
        let only = "if (location.protocol !== \"cmux-page:\" || window !== window.top) return;\n"
        let event = ChromiumPageHostWire.jsonString(postEventName)
        let unavailable = ChromiumPageHostWire.jsonString(unavailableEventName)
        let channelName = ChromiumPageHostWire.jsonString(channel)
        let relay = """
        (() => {
          \(only)
          document.addEventListener(\(event), (event) => {
            if (typeof event.detail !== "string") return;
            if (typeof cmuxPost !== "function") {
              document.dispatchEvent(new CustomEvent(\(unavailable), { detail: event.detail }));
              return;
            }
            cmuxPost(\(channelName), JSON.stringify({ url: location.href, message: event.detail }));
          }, true);
        })();
        """
        let host = api(handlers: handlers, transport: """
          const send = (text) => { document.dispatchEvent(new CustomEvent(\(event), { detail: text })); };
          document.addEventListener(\(unavailable), (event) => {
            console.error("cmux page host: no page channel");
            if (typeof event.detail === "string") failText(event.detail);
          }, true);
        """)
        let page = """
        (() => {
          \(only)
        \(batch([host] + documentScripts))
        })();
        """
        return [ChromiumPageRendererScript(world: world, source: relay, allFrames: false),
                ChromiumPageRendererScript(world: "", source: page, allFrames: false)]
    }

    /// The API over `transport`, which defines `send(text)` and may call `failText(text)` for a
    /// message that cannot go out. ``addHandlersName`` adds handler names to the document later.
    /// Each document has its own `doc` id: a reply carries the id of the document that asked, so
    /// after a reload it settles nothing in the new document.
    nonisolated private static func api(handlers: [String], transport: String) -> String {
        let names = ([PageHostTrust.handlerName] + handlers).map(ChromiumPageHostWire.jsonString).joined(separator: ", ")
        let replying = ChromiumPageHostWire.jsonString(PageHostTrust.handlerName)
        let failure = ChromiumPageHostWire.failureJSON(code: "native.page_host_unavailable", message: "Page host unavailable")
        return """
        (() => {
          if (globalThis.__cmuxPageHostInstalled) return;
          Object.defineProperty(globalThis, "__cmuxPageHostInstalled", { value: true });
          const pending = new Map();
          let next = 1;
          const doc = (globalThis.crypto && crypto.randomUUID) ? crypto.randomUUID() : String(Math.random()).slice(2) + String(Date.now());
          const failText = (text) => {
            let seq;
            try { seq = JSON.parse(text).seq; } catch (_) { return; }
            const done = pending.get(seq);
            if (done) { pending.delete(seq); done(\(failure)); }
          };
        \(transport)
          Object.defineProperty(globalThis, "\(resolveName)", {
            value: (seq, reply, from) => {
              if (from !== undefined && from !== doc) return;
              const done = pending.get(seq);
              if (done) { pending.delete(seq); done(reply); }
            },
          });
          const add = (list) => {
            const handlers = {};
            for (const name of list) {
              if (typeof name !== "string") continue;
              handlers[name] = {
                postMessage(body) {
                  if (name !== \(replying)) { send(JSON.stringify({ name, body })); return undefined; }
                  return new Promise((resolve) => {
                    const seq = next++;
                    pending.set(seq, resolve);
                    send(JSON.stringify({ name, seq, doc, body }));
                  });
                },
              };
            }
            const webkit = globalThis.webkit ?? {};
            globalThis.webkit = { ...webkit, messageHandlers: { ...(webkit.messageHandlers ?? {}), ...handlers } };
          };
          add([\(names)]);
          Object.defineProperty(globalThis, "\(addHandlersName)", { value: (list) => { if (Array.isArray(list)) add(list); } });
        })();
        """
    }
}
