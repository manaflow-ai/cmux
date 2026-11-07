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
/// - it wraps `AudioScheduledSourceNode.prototype.start` (oscillators, buffer and constant
///   sources) and keeps each started source until its `ended`; a source of a context that is not
///   `running` (suspended, closed) makes no sound;
/// - on any change it fires `cmux-media-hidden-changed` on the document; the observer then asks
///   (`cmux-media-hidden-ask`) and the answer comes back at once as `cmux-media-hidden`, a JSON
///   string: the element outside the document that plays (else one that played), or
///   `{playing: true, soundOnly: true}` while a Web Audio source sounds, or null;
/// - the media commands reach that element through `cmux-media-hidden-command` (`playPause`,
///   `play`, `pause`, `toggleMute`, `seek:<seconds>`, then `|started` when the document has an element
///   that played, which wins over a paused hidden one); the listener cancels the event when it acted.
///
/// Nothing here keeps a timer: an idle page pays one wrapper call per `play()` and per source
/// start. A page can see and replace the wrappers, which only changes its own tab's speaker.
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
      const watch = (e) => {
        if (seen.has(e)) return;
        seen.add(e);
        elements.add(new WeakRef(e));
        for (const type of kinds) e.addEventListener(type, changed, true);
      };
      const play = HTMLMediaElement.prototype.play;
      Object.defineProperty(HTMLMediaElement.prototype, 'play', {
        configurable: true, writable: true,
        value: function () {
          try { if (hidden(this)) { watch(this); changed(); } } catch (_) {}
          return play.apply(this, arguments);
        },
      });
      const attachShadow = Element.prototype.attachShadow;
      if (attachShadow) {
        Object.defineProperty(Element.prototype, 'attachShadow', {
          configurable: true, writable: true,
          value: function () {
            const root = attachShadow.apply(this, arguments);
            try {
              root.addEventListener('play', (event) => {
                const e = event.target;
                if (e instanceof HTMLMediaElement) { watch(e); changed(); }
              }, true);
            } catch (_) {}
            return root;
          },
        });
      }
      const Scheduled = window.AudioScheduledSourceNode;
      if (Scheduled && Scheduled.prototype.start) {
        const start = Scheduled.prototype.start;
        Object.defineProperty(Scheduled.prototype, 'start', {
          configurable: true, writable: true,
          value: function () {
            const result = start.apply(this, arguments);
            try {
              const node = this, context = node.context;
              sources.add(node);
              node.addEventListener('ended', () => { sources.delete(node); changed(); }, { once: true });
              if (context && !contexts.has(context)) {
                contexts.add(context);
                context.addEventListener('statechange', () => {
                  if (context.state === 'closed') for (const s of sources) if (s.context === context) sources.delete(s);
                  changed();
                });
              }
              changed();
            } catch (_) {}
            return result;
          },
        });
      }
      // The hidden element that plays, else one that played and has not ended.
      const element = () => {
        let started = null;
        for (const ref of elements) {
          const e = ref.deref();
          if (!e || e.ended && !e.isConnected) { elements.delete(ref); continue; }
          if (!hidden(e)) continue;
          if (!e.paused && !e.ended) return e;
          if (!started && e.currentTime > 0 && !e.ended) started = e;
        }
        return started;
      };
      const sounding = () => {
        for (const s of sources) if (s.context && s.context.state === 'running') return true;
        return false;
      };
      const answer = () => {
        const e = element();
        if (e && (!e.paused || !sounding())) {
          return {
            playing: !e.paused && !e.ended, muted: e.muted || e.volume === 0, video: e.tagName === 'VIDEO',
            position: e.currentTime, duration: isFinite(e.duration) ? e.duration : null, rate: e.playbackRate,
          };
        }
        return sounding() ? { playing: true, soundOnly: true } : null;
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
