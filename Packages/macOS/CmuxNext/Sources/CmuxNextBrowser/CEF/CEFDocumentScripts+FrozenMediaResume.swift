import Foundation

/// A video that played in a hidden Chromium tab stayed paused after the tab came back (2026-11-25, the in-tree
/// video-freeze report). A hidden page freezes after `browser.freezeHiddenTabs` (30 s by default;
/// `BrowserHibernation`), and Blink pauses each playing media element when its frame freezes
/// (`HTMLMediaElement::ContextLifecycleStateChanged`, pause reason `kFrameFrozen`). Through M139 Blink played such an
/// element again when the frame ran again (`kFrozenAutoResumeMedia`, `paused_by_context_paused_`); M140 removed
/// that, so in M157 nothing plays it again: the page's own `resume` comes, its timers run, and its video stays
/// paused at the frame it froze on. Chrome freezes far less (Battery Saver, its freezing votes), and pauses a
/// muted file video in a hidden tab itself (`WebMediaPlayerImpl`, `kPageHidden`), playing it again when the tab
/// shows; a MediaStream video (a camera preview, a canvas `captureStream()`, a dashboard's stream) keeps playing
/// while hidden, so the freeze is what pauses it.
///
/// This script undoes the freeze's pause, as Blink did before M140: from document start in every frame, in the
/// page's world, it notes on `freeze` (which Blink fires before the frame freezes, while the elements still play)
/// each media element that plays, in the document, in a shadow root or detached, and on `resume` (after the frame
/// runs again) it plays each one the freeze left paused. It does not play:
/// - an element the page paused itself, before the freeze or in its own `freeze` handler (it wraps
///   `HTMLMediaElement.prototype.pause`, a proxy, as `BrowserMediaState.hiddenSoundScript` wraps `play`);
/// - an element the page removed from, or added to, a document meanwhile;
/// - anything after the back/forward cache (`pagehide` with `persisted`): Chrome leaves that media paused.
///
/// Chromium only: WebKit fires no `freeze` or `resume`. It keeps no timer and no work while idle (one wrapper
/// call per `play()` and `pause()`); a page can see the wrappers, which only changes its own media.
nonisolated extension CEFDocumentScripts {
    /// The page-world script that plays again what the hidden-tab freeze paused (see above).
    static let frozenMediaResume = #"""
    (() => {
      const key = Symbol.for('cmux.frozenMediaResume');
      if (window[key] || typeof HTMLMediaElement === 'undefined') return;
      Object.defineProperty(window, key, { value: true });
      // Each element that started playing through play() or in a shadow root (the document's own are found by
      // query): a shadow root's or a detached element is otherwise out of reach.
      const known = new Set();
      const seen = new WeakSet();
      const note = (e) => {
        if (!(e instanceof HTMLMediaElement) || seen.has(e)) return;
        seen.add(e);
        known.add(new WeakRef(e));
      };
      // From `freeze` to `resume`: each element that played when the frame froze, and whether it was in a document.
      let held = null;
      // The page entered the back/forward cache (`pagehide` persisted) and has not shown since.
      let cached = false;
      const wrap = (owner, name, before) => {
        const original = owner && Object.prototype.hasOwnProperty.call(owner, name) ? owner[name] : null;
        if (typeof original !== 'function') return;
        owner[name] = new Proxy(original, {
          apply(target, self, args) {
            try { before(self); } catch (_) {}
            return Reflect.apply(target, self, args);
          },
        });
      };
      wrap(HTMLMediaElement.prototype, 'play', note);
      // The page's own pause wins: that element stays paused.
      wrap(HTMLMediaElement.prototype, 'pause', (e) => { if (held) held.delete(e); });
      // A shadow root's element that autoplays: its media events do not leave the root.
      const shadow = Element.prototype.attachShadow;
      if (typeof shadow === 'function') {
        Element.prototype.attachShadow = new Proxy(shadow, {
          apply(target, self, args) {
            const root = Reflect.apply(target, self, args);
            try { root.addEventListener('play', (event) => note(event.target), true); } catch (_) {}
            return root;
          },
        });
      }
      addEventListener('pagehide', (event) => { cached = !!event.persisted; }, true);
      addEventListener('pageshow', () => { cached = false; }, true);
      document.addEventListener('freeze', () => {
        held = null;
        if (cached) return;
        const playing = new Map();
        const look = (e) => { if (e && !e.paused && !e.ended && !playing.has(e)) playing.set(e, e.isConnected); };
        document.querySelectorAll('video, audio').forEach(look);
        for (const ref of known) {
          const e = ref.deref();
          if (e) look(e); else known.delete(ref);
        }
        if (playing.size) held = playing;
      }, true);
      document.addEventListener('resume', () => {
        const list = held;
        held = null;
        if (!list || cached) return;
        for (const [e, connected] of list) {
          if (e.paused && !e.ended && e.isConnected === connected) {
            try { const p = e.play(); if (p && p.catch) p.catch(() => {}); } catch (_) {}
          }
        }
      }, true);
    })();
    """#
}
