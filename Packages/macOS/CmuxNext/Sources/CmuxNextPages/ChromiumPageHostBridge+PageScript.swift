/// The page script of ``ChromiumPageHostBridge``: the WebKit-shaped API a cmux page calls in Chromium.
extension ChromiumPageHostBridge {
    /// Installs `window.webkit.messageHandlers.<name>` for ``PageHostTrust/handlerName`` (with
    /// replies) and each of `handlers` (without). The posts of one task leave together at its
    /// microtask checkpoint as one call (a JSON array of several, up to ``maximumPostCharacters``):
    /// on the page channel when `channelEvent` is set and its relay takes the post, else on the
    /// binding, which the document then keeps, so its posts stay in order. Posts made before either
    /// exists wait in the page and go out once one does. Ends with ``pushReceiverScript``.
    ///
    /// - Parameters:
    ///   - handlers: Extra handler names whose messages need no reply.
    ///   - channelEvent: The page channel event (``PageChromiumPage/pageHostEvent``); nil: the binding only.
    public static func pageScript(handlers: [String], channelEvent: String? = nil) -> String {
        let names = ([PageHostTrust.handlerName] + handlers).map(ChromiumPageHostWire.jsonString).joined(separator: ", ")
        let replying = ChromiumPageHostWire.jsonString(PageHostTrust.handlerName)
        let event = channelEvent.map(ChromiumPageHostWire.jsonString) ?? "null"
        return """
        (() => {
          if (globalThis.__cmuxPageHostInstalled) return;
          Object.defineProperty(globalThis, "__cmuxPageHostInstalled", { value: true });
          const channelEvent = \(event);
          // This document's token: every document counts seq from 1, so a reply names its document.
          const doc = (() => {
            const c = globalThis.crypto;
            if (typeof c?.randomUUID === "function") return c.randomUUID();
            if (typeof c?.getRandomValues === "function") return Array.from(c.getRandomValues(new Uint32Array(4)), (n) => n.toString(36)).join("-");
            return Math.random().toString(36).slice(2) + "-" + Date.now().toString(36);
          })();
          const pending = new Map();
          const queue = [];
          let next = 1;
          let retries = 0;
          let waiting = false;
          let bindingUsed = false;
          const viaChannel = (text) => channelEvent !== null && !bindingUsed
            && !document.dispatchEvent(new CustomEvent(channelEvent, { detail: text, cancelable: true }));
          const viaBinding = (text) => {
            const binding = globalThis.\(bindingName);
            if (typeof binding !== "function") return false;
            binding(text);
            bindingUsed = true;
            return true;
          };
          const flush = () => {
            while (queue.length) {
              let size = queue[0].length;
              let count = 1;
              while (count < queue.length && size + queue[count].length <= \(maximumPostCharacters)) size += queue[count++].length;
              const text = count === 1 ? queue[0] : "[" + queue.slice(0, count).join(",") + "]";
              if (!viaChannel(text) && !viaBinding(text)) return false;
              queue.splice(0, count);
            }
            return true;
          };
          const drain = () => {
            if (flush() || ++retries > 400) { waiting = false; return; }
            setTimeout(drain, 5);
          };
          const send = (text) => {
            queue.push(text);
            if (waiting) return;
            waiting = true;
            retries = 0;
            // At the task's microtask checkpoint (a promise reaction where `queueMicrotask` is missing).
            if (typeof queueMicrotask === "function") queueMicrotask(drain); else Promise.resolve().then(drain);
          };
          const resolve = (seq, reply, from) => {
            if (from !== undefined && from !== doc) return;
            const done = pending.get(seq);
            if (done) { pending.delete(seq); done(reply); }
          };
          Object.defineProperty(globalThis, "\(resolveName)", { value: resolve });
          const handlers = {};
          for (const name of [\(names)]) {
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
        \(pushReceiverScript)
        })();
        """
    }

    /// The page script's half of the page push channel, inside ``pageScript(handlers:channelEvent:)``
    /// where `resolve` settles a reply. Where the fork defines `cmuxPageListen` (the main frame of a
    /// cmux-page document, fork API 43) it registers the document's one receiver. A push is JSON:
    /// an array is one run of envelopes for the page's receiver (pageClient.ts registers it with
    /// ``listenName``; until it does, the runs wait here, at most ``maximumHeldPushes``), and
    /// `{"r": seq, "d": doc, "v": reply}` is a reply, settled only when `doc` is this document's token.
    nonisolated static let pushReceiverScript = """
          if (typeof globalThis.cmuxPageListen === "function") {
            let receiver = null;
            let held = [];
            const toPage = (envelopes) => {
              if (receiver) { receiver(envelopes); return; }
              if (held.length < \(maximumHeldPushes)) held.push(envelopes);
              else if (held.length === \(maximumHeldPushes)) { held.push(null); console.error("cmux page: no receiver; host events dropped"); }
            };
            globalThis.cmuxPageListen((text) => {
              const message = JSON.parse(text);
              if (Array.isArray(message)) toPage(message);
              else if (message && typeof message.r === "number" && message.d === doc) resolve(message.r, message.v);
            });
            Object.defineProperty(globalThis, "\(listenName)", {
              value: (fn) => {
                if (receiver || typeof fn !== "function") return false;
                receiver = fn;
                const waiting = held;
                held = [];
                for (const envelopes of waiting) if (envelopes) receiver(envelopes);
                return true;
              },
            });
          }
    """

    /// Runs of envelopes the page script keeps for a page that has no receiver yet.
    nonisolated static let maximumHeldPushes = 10_000
}
