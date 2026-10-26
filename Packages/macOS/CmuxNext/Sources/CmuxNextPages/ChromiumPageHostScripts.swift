public import Foundation

/// One document-start script the app installs in every Chromium renderer once (fork API 29,
/// ``ChromiumPageHostBridge/rendererScripts(handlers:world:channel:)``).
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
    /// binding. Messages posted before the binding exists wait in the page and go out once it appears.
    ///
    /// - Parameter handlers: The fire-and-forget handler names.
    /// - Returns: The script.
    nonisolated public static func pageScript(handlers: [String]) -> String {
        api(onlyIn: "", handlers: handlers, transport: """
          const queue = [];
          let retries = 0;
          const flush = () => {
            const binding = globalThis.\(bindingName);
            if (typeof binding !== "function") return false;
            while (queue.length) binding(queue.shift());
            return true;
          };
          const retry = () => {
            if (flush() || ++retries > 400) return;
            setTimeout(retry, 5);
          };
          const send = (text) => {
            queue.push(text);
            if (!flush() && queue.length === 1) { retries = 0; retry(); }
          };
        """)
    }

    /// The renderer path's scripts, installed once for every browser before Chromium starts. Both
    /// return outside the main frame of a `cmux-page:` document, so a web page never gets them.
    ///
    /// - The page world gets the API; a post goes to the channel world as a ``postEventName``
    ///   event whose detail is the message text (Blink hands a `CustomEvent` detail across
    ///   worlds, third_party/blink/renderer/core/events/custom_event.cc).
    /// - The channel world posts that text on `channel` (`cmuxPost`); the browser reads the
    ///   sender from the frame that delivered it (``PageChromiumSender``).
    ///
    /// - Parameters:
    ///   - handlers: Fire-and-forget handler names every page has; a page adds its own at commit
    ///     (``rebind()``).
    ///   - world: The isolated world `channel` lives in.
    ///   - channel: The page channel the fork delivers as a page message.
    /// - Returns: The channel world's script, then the page world's.
    nonisolated public static func rendererScripts(handlers: [String], world: String, channel: String) -> [ChromiumPageRendererScript] {
        let only = "if (location.protocol !== \"cmux-page:\" || window !== window.top) return;\n"
        let event = ChromiumPageHostWire.jsonString(postEventName)
        let channelName = ChromiumPageHostWire.jsonString(channel)
        let relay = """
        (() => {
          \(only)
          const queue = [];
          let retries = 0;
          const flush = () => {
            if (typeof cmuxPost !== "function") return false;
            while (queue.length) cmuxPost(\(channelName), queue.shift());
            return true;
          };
          const retry = () => {
            if (flush() || ++retries > 400) return;
            setTimeout(retry, 5);
          };
          document.addEventListener(\(event), (event) => {
            if (typeof event.detail !== "string") return;
            queue.push(event.detail);
            if (!flush() && queue.length === 1) { retries = 0; retry(); }
          }, true);
        })();
        """
        let page = api(onlyIn: only, handlers: handlers, transport: """
          const send = (text) => { document.dispatchEvent(new CustomEvent(\(event), { detail: text })); };
        """)
        return [ChromiumPageRendererScript(world: world, source: relay, allFrames: false),
                ChromiumPageRendererScript(world: "", source: page, allFrames: false)]
    }

    /// The API over `transport`, which defines `send(text)`. `onlyIn` returns early where the API
    /// does not belong. ``addHandlersName`` adds handler names to the document later.
    nonisolated private static func api(onlyIn: String, handlers: [String], transport: String) -> String {
        let names = ([PageHostTrust.handlerName] + handlers).map(ChromiumPageHostWire.jsonString).joined(separator: ", ")
        let replying = ChromiumPageHostWire.jsonString(PageHostTrust.handlerName)
        return """
        (() => {
          \(onlyIn)if (globalThis.__cmuxPageHostInstalled) return;
          Object.defineProperty(globalThis, "__cmuxPageHostInstalled", { value: true });
          const pending = new Map();
          let next = 1;
        \(transport)
          Object.defineProperty(globalThis, "\(resolveName)", {
            value: (seq, reply) => { const done = pending.get(seq); if (done) { pending.delete(seq); done(reply); } },
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
                    send(JSON.stringify({ name, seq, body }));
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
