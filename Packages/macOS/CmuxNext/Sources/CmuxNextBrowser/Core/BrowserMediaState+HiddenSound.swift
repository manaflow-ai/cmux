import Foundation

/// Sound the observer cannot find (issue 38062): `observerScript` looks for `<video>` and `<audio>`
/// in its document, so a detached `new Audio()` (web radios, stream players, sound effects), an
/// element in a shadow root (its media events do not leave the root) and Web Audio played with no
/// speaker on the tab or its sidebar row, and no Mute. Chrome shows its speaker for every sound a
/// tab makes. Those objects live in the page's world only, so `hiddenSoundScript` runs there, in
/// every frame from document start (both engines install it next to `actionsScript`):
///
/// - it wraps `HTMLMediaElement.prototype.play` and `Element.prototype.attachShadow` (a capture
///   listener on each new root, open or closed), and keeps each element it saw play weakly;
/// - it wraps `start` of every source node that owns one (`AudioScheduledSourceNode`, and
///   `AudioBufferSourceNode`'s own) and keeps each started source of a live `AudioContext` until
///   its `ended`; a source of a context that is not `running` (suspended, closed) makes no sound;
/// - the wrappers are proxies, so the page still sees the native functions' name and length;
/// - a hidden element reports `video: false`: Picture in Picture finds only the document's videos;
/// - on any change it fires `cmux-media-hidden-changed` on the document; the observer then asks
///   (`cmux-media-hidden-ask`) and the answer comes back at once as `cmux-media-hidden`, a JSON
///   string `{element, sound}`: the element outside the document that plays (else one that
///   played, else null) and whether a Web Audio source sounds; null when neither;
/// - the media commands reach that element through `cmux-media-hidden-command` (`playPause`,
///   `play`, `pause`, `toggleMute`, `seek:<seconds>`, then `|started` when the document has an element
///   that played, which wins over a paused hidden one); the listener cancels the event when it acted.
///
/// Nothing here keeps a timer (one 2 s timeout after a source ends): an idle page pays one
/// wrapper call per `play()` and per source start. Not heard: a never-ending silent source (a
/// keep-alive loop at gain 0) shows the speaker; AudioWorklet, ScriptProcessor and MediaStream
/// output show none. A page can see and replace the wrappers, which only changes its own tab's speaker.
nonisolated extension BrowserMediaState {
    /// The page-world recorder of sound outside the document (see above).
    static let hiddenSoundScript = #"""
    (() => {
      const key = Symbol.for('cmux.mediaHidden');
      if (window[key] || typeof HTMLMediaElement === 'undefined') return;
      Object.defineProperty(window, key, { value: true });
      const elements = new Set();
      const seen = new WeakSet();
      const sources = new Set();
      const contexts = new WeakSet();
      const changed = () => document.dispatchEvent(new CustomEvent('cmux-media-hidden-changed'));
      const hidden = (e) => !e.isConnected || e.getRootNode() !== document;
      const kinds = ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange', 'loadedmetadata', 'durationchange',
        'seeked', 'ratechange'];
      // `seen`: the element has its listeners; `tracked`: it is in `elements` (dropped once ended,
      // and back when it plays again, as a reused `new Audio()` or sound effect does).
      const tracked = new WeakSet();
      const watch = (e) => {
        if (!tracked.has(e)) { tracked.add(e); elements.add(new WeakRef(e)); }
        if (seen.has(e)) return;
        seen.add(e);
        for (const type of kinds) e.addEventListener(type, changed, true);
      };
      // Wrappers as proxies keep the originals' name, length and native toString (as `BrowserPageBusy`).
      const wrap = (owner, name, after) => {
        const original = owner && Object.prototype.hasOwnProperty.call(owner, name) ? owner[name] : null;
        if (typeof original !== 'function') return;
        owner[name] = new Proxy(original, {
          apply(target, self, args) {
            const result = Reflect.apply(target, self, args);
            try { after(self, result); } catch (_) {}
            return result;
          },
        });
      };
      wrap(HTMLMediaElement.prototype, 'play', (e) => { if (hidden(e)) { watch(e); changed(); } });
      wrap(Element.prototype, 'attachShadow', (_, root) => {
        root.addEventListener('play', (event) => {
          const e = event.target;
          if (e instanceof HTMLMediaElement) { watch(e); changed(); }
        }, true);
      });
      // A source that ends keeps the speaker 2 s, as Chrome's, so short sound effects do not blink
      // it; one timeout per end, none while idle.
      let heard = 0;
      const quiet = () => {
        heard = Date.now();
        setTimeout(changed, 2100);
        changed();
      };
      // `AudioBufferSourceNode` declares its own `start`, which hides the shared one: wrap each owner.
      // An offline context renders to a buffer (no sound), and a closed one never plays again.
      const started = (node) => {
        const context = node.context;
        if (!context || context.state === 'closed' || (window.OfflineAudioContext && context instanceof OfflineAudioContext)) return;
        sources.add(node);
        node.addEventListener('ended', () => { sources.delete(node); quiet(); }, { once: true });
        if (!contexts.has(context)) {
          contexts.add(context);
          context.addEventListener('statechange', () => {
            if (context.state === 'closed') for (const s of sources) if (s.context === context) sources.delete(s);
            changed();
          });
        }
        changed();
      };
      for (const name of ['AudioScheduledSourceNode', 'AudioBufferSourceNode', 'OscillatorNode', 'ConstantSourceNode']) {
        if (window[name]) wrap(window[name].prototype, 'start', started);
      }
      // The hidden element that plays, else one that played and has not ended.
      const element = () => {
        let started = null;
        for (const ref of elements) {
          const e = ref.deref();
          if (!e || e.ended && !e.isConnected) { elements.delete(ref); if (e) tracked.delete(e); continue; }
          if (!hidden(e)) continue;
          if (!e.paused && !e.ended) return e;
          if (!started && e.currentTime > 0 && !e.ended) started = e;
        }
        return started;
      };
      const sounding = () => {
        for (const s of sources) if (s.context && s.context.state === 'running') return true;
        return Date.now() - heard < 2000;
      };
      // `{element, sound}`: the hidden element's state (or null), and whether Web Audio sounds.
      const answer = () => {
        const e = element();
        const sound = sounding();
        if (!e && !sound) return null;
        return {
          sound,
          element: e ? {
            playing: !e.paused && !e.ended, muted: e.muted || e.volume === 0, video: false,
            position: e.currentTime, duration: isFinite(e.duration) ? e.duration : null, rate: e.playbackRate,
          } : null,
        };
      };
      document.addEventListener('cmux-media-hidden-ask', () => {
        let detail = 'null';
        try { detail = JSON.stringify(answer()); } catch (_) {}
        document.dispatchEvent(new CustomEvent('cmux-media-hidden', { detail }));
      }, true);
      document.addEventListener('cmux-media-hidden-command', (event) => {
        // `|started`: the document has an element that played, which the observer reports unless this one plays.
        const [command, started] = (typeof event.detail === 'string' ? event.detail : '').split('|');
        const e = element();
        if (!e || (started && e.paused)) return;
        if (command === 'playPause') { if (e.paused) { e.play().catch(() => {}); } else { e.pause(); } }
        else if (command === 'play') { e.play().catch(() => {}); }
        else if (command === 'pause') { e.pause(); }
        else if (command === 'toggleMute') { e.muted = !e.muted; }
        else if (command.startsWith('seek:')) { const to = Number(command.slice(5)); if (isFinite(to)) e.currentTime = Math.max(0, to); }
        else return;
        event.preventDefault();
      }, true);
    })();
    """#
}
