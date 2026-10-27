/// The page script of ``ChromiumPageHostBridge``: the WebKit-shaped API a cmux page calls in Chromium.
extension ChromiumPageHostBridge {
    /// Installs `window.webkit.messageHandlers.<name>` for ``PageHostTrust/handlerName`` (with
    /// replies) and each of `handlers` (without). The posts of one task leave together at its
    /// microtask checkpoint as one call (a JSON array of several, up to ``maximumPostCharacters``):
    /// on the page channel when `channelEvent` is set and its relay takes the post, else on the
    /// binding, which the document then keeps, so its posts stay in order. Posts made before either
    /// exists wait in the page and go out once one does.
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
          const doc = Math.random().toString(36).slice(2) + Date.now().toString(36);
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
            queueMicrotask(drain);
          };
          Object.defineProperty(globalThis, "\(resolveName)", {
            value: (seq, reply, from) => {
              if (from !== undefined && from !== doc) return;
              const done = pending.get(seq);
              if (done) { pending.delete(seq); done(reply); }
            },
          });
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
        })();
        """
    }
}
