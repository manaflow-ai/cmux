import Foundation

/// The page scripts behind the media hub (cx-6qwm.2), the same in both
/// engines; no engine API reports media. `observerScript` runs in an isolated
/// world from document start in every frame: it watches media elements
/// (their events, in the capture phase) and `navigator.mediaSession`, and
/// posts `{frame, report}` when what plays changes (report null once
/// nothing does, or when the document goes). `frame` is an id the observer
/// picks for its document: the tab keeps one report per frame
/// (`BrowserMediaFrames`), so one frame's null never erases another frame's
/// report. A frame that never played posts nothing. `actionsScript` runs in the page's world: it records the page's
/// `mediaSession` action handlers so Previous and Next can call them
/// (handlers live in the page's world only); a page can see that wrapper,
/// so those two are best effort. Media elements outside the document (a
/// detached `new Audio()`) are not seen. A `cmux-media-mute` event mutes
/// (or unmutes) the frame's media elements, keeps muting the ones that play
/// next, and passes on to the frame's child frames. A video floating in
/// Picture in Picture is the one reported, playing or not, until it comes back.
/// The observer keeps a timer only while what it reported plays: an idle
/// frame costs its renderer no wakeup and no work per DOM change. A report
/// the channel was not ready for waits, with no timer, for the channel's
/// ready call (``readyHook``: Chromium's bridge calls it right after each
/// binding add), the next media event or the page showing again. A paused
/// element the page removes (its events fire on a detached node no listener
/// here sees) reports null at once: while a paused report is held, the
/// observer watches the child lists of that element's ancestors (not their
/// subtrees), and stops watching when the report plays or clears.
nonisolated extension BrowserMediaState {
    /// WebKit's message handler and Chromium's binding.
    static let channel = "cmuxMedia"
    /// The isolated world the observer runs in.
    static let world = "cmux-media"
    /// The function the observer puts on its world's `window`; calling it says the channel
    /// exists now, and a report that waited for it is sent (`CEFMediaBridge` calls it once in the
    /// existing worlds after each binding add).
    static let readyHook = "__cmuxMediaReady"

    /// The observer, posting with `post` (a JS expression taking `message`,
    /// `{frame, report}`) once `ready` (a JS expression) is true.
    static func observerScript(post: String, ready: String = "true") -> String {
        #"""
        (() => {
          if (window.__cmuxMedia) return;
          window.__cmuxMedia = true;
          let last = '', reported = false, pending = false, heartbeat = false, timer = 0, actions = '', tabMuted = false, seeked = false;
          // What the last look found playing, and the one-second look-again while it plays (`follow`).
          let playing = false, ticks = 0, ticker = 0;
          // The element last reported, and the watch on its ancestors' child lists while it is
          // held paused (`guardHeld`), with the parent it was made for.
          let held = null, watch = null, watchedParent = null;
          // This document's id: the tab keeps one report per frame.
          const frame = Math.random().toString(36).slice(2) + Date.now().toString(36);
          // The elements the tab's mute muted, which Unmute unmutes.
          const hushed = new WeakSet();
          const media = (e) => !!e && (e.tagName === 'VIDEO' || e.tagName === 'AUDIO');
          const hush = (e) => { if (tabMuted && !e.muted) { e.muted = true; hushed.add(e); } };
          const send = (report) => {
            if (!(\#(ready))) { pending = true; return false; }
            pending = false;
            const message = { frame, report };
            try { \#(post); return true; } catch (_) { return false; }
          };
          // The video in Picture in Picture: Chromium's (and WebKit's) API, or WebKit's presentation mode.
          const floating = () => document.pictureInPictureElement
            || Array.from(document.querySelectorAll('video')).find((e) => e.webkitPresentationMode === 'picture-in-picture') || null;
          const active = () => {
            const shown = floating();
            if (shown) return shown;
            const all = Array.from(document.querySelectorAll('video, audio'));
            return all.find((e) => !e.paused && !e.ended) || all.find((e) => e.currentTime > 0 && !e.ended) || null;
          };
          const artwork = (meta) => {
            const list = meta && meta.artwork ? Array.from(meta.artwork) : [];
            const best = list[list.length - 1];
            try { return best ? new URL(best.src, location.href).href : ''; } catch (_) { return ''; }
          };
          const look = () => {
            playing = false;
            const element = active();
            if (!element) {
              if (reported && send(null)) { reported = false; last = ''; held = null; }
              return;
            }
            const meta = navigator.mediaSession ? navigator.mediaSession.metadata : null;
            const state = {
              title: (meta && meta.title) || document.title || '',
              artist: (meta && meta.artist) || '', album: (meta && meta.album) || '',
              artwork: artwork(meta), playing: !element.paused && !element.ended,
              muted: element.muted || element.volume === 0, video: element.tagName === 'VIDEO', pip: floating() === element,
              tabMuted, actions,
            };
            playing = state.playing;
            // The position leaves the key: the heartbeat corrects its drift, and a seek reports at once.
            const key = JSON.stringify(state) + '#' + (isFinite(element.duration) ? Math.round(element.duration) : '')
              + (seeked ? '#' + Math.round(element.currentTime) : '');
            seeked = false;
            state.position = element.currentTime;
            state.duration = isFinite(element.duration) ? element.duration : null;
            state.rate = element.playbackRate;
            // Again every few seconds while it plays: the position the app runs on may have drifted.
            if (key === last && !heartbeat) return;
            if (!send(state)) return;
            last = key;
            reported = true;
            held = element;
          };
          // Metadata changes fire no event: look again every second while what this frame reported
          // plays (every third look sends it again with its position). Nothing else keeps a timer,
          // so a frame with nothing playing (every idle page, hidden or shown) never wakes its
          // renderer. A report that waits for the channel keeps none: the channel's ready call
          // (`readyHook`), the next media event or the next show sends it.
          const follow = () => {
            const on = playing && reported;
            if (on && !ticker) {
              ticks = 0;
              ticker = setInterval(() => {
                ticks += 1;
                heartbeat = reported && ticks % 3 === 0;
                schedule();
              }, 1000);
            } else if (!on && ticker) {
              clearInterval(ticker);
              ticker = 0;
            }
          };
          const unwatch = () => {
            if (watch) watch.disconnect();
            watch = null;
            watchedParent = null;
          };
          // A paused report's element can leave the document with no media event (a route swap
          // removes it or a container of it). While one is held, watch the child lists of its
          // ancestors (each one level, no subtree), up through shadow roots: a removal looks again
          // at once. Off while it plays (the one-second look sees it go) or nothing is reported.
          const guardHeld = () => {
            if (!reported || playing || !held || !held.isConnected) { unwatch(); return; }
            if (watch && watchedParent === held.parentNode) return;
            unwatch();
            watchedParent = held.parentNode;
            watch = new MutationObserver(() => {
              if (!held || !held.isConnected) { unwatch(); schedule(); }
              else if (held.parentNode !== watchedParent) guardHeld();
            });
            for (let node = held.parentNode; node; node = node.parentNode || node.host || null) {
              watch.observe(node, { childList: true });
            }
          };
          const report = () => {
            timer = 0;
            look();
            follow();
            guardHeld();
          };
          const schedule = () => { if (!timer) timer = setTimeout(report, 250); };
          // The channel exists now (Chromium's bridge calls this once after each binding add): a
          // report that waited for it goes.
          window.\#(readyHook) = () => { if (pending) schedule(); };
          for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange', 'loadedmetadata', 'durationchange',
            'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged']) {
            addEventListener(type, schedule, true);
          }
          // The document goes (navigation, its frame removed): its report goes with it. A page
          // restored from the back-forward cache looks again.
          addEventListener('pagehide', () => {
            if (reported && send(null)) { reported = false; last = ''; held = null; }
            follow();
            guardHeld();
          }, true);
          addEventListener('pageshow', (event) => { if (event.persisted) schedule(); }, true);
          // The page shows again: a report that waits, or a reported element gone meanwhile, looks
          // again. One check per show.
          addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'hidden') return;
            if (pending || (reported && held && !held.isConnected)) schedule();
          }, true);
          for (const type of ['seeked', 'ratechange']) {
            addEventListener(type, () => { seeked = true; schedule(); }, true);
          }
          for (const type of ['play', 'volumechange', 'loadedmetadata']) {
            addEventListener(type, (event) => { if (media(event.target)) hush(event.target); }, true);
          }
          const muteTab = (on) => {
            tabMuted = on;
            for (const e of document.querySelectorAll('video, audio')) {
              if (on) { hush(e); } else if (hushed.has(e)) { hushed.delete(e); e.muted = false; }
            }
            for (let i = 0; i < frames.length; i++) {
              try { frames[i].postMessage({ cmuxMediaMute: on }, '*'); } catch (_) {}
            }
            schedule();
          };
          document.addEventListener('cmux-media-mute', (event) => {
            if (typeof event.detail === 'boolean') muteTab(event.detail);
          }, true);
          // A frame that loads after the mute hears it at once.
          addEventListener('load', (event) => {
            const frame = event.target;
            if (tabMuted && frame && (frame.tagName === 'IFRAME' || frame.tagName === 'FRAME')) {
              try { frame.contentWindow.postMessage({ cmuxMediaMute: true }, '*'); } catch (_) {}
            }
          }, true);
          addEventListener('message', (event) => {
            const data = event.data;
            if (window !== top && data && typeof data.cmuxMediaMute === 'boolean') muteTab(data.cmuxMediaMute);
          });
          document.addEventListener('cmux-media-actions', (event) => {
            actions = typeof event.detail === 'string' ? event.detail : '';
            schedule();
          }, true);
        })();
        """#
    }

    /// The page-world recorder of `mediaSession` action handlers.
    static let actionsScript = #"""
    (() => {
      const key = Symbol.for('cmux.mediaAction');
      if (window[key] || typeof MediaSession === 'undefined') return;
      const handlers = new Map();
      const original = MediaSession.prototype.setActionHandler;
      const announce = () => document.dispatchEvent(new CustomEvent('cmux-media-actions', { detail: Array.from(handlers.keys()).join(',') }));
      Object.defineProperty(MediaSession.prototype, 'setActionHandler', {
        configurable: true, writable: true,
        value: function (action, handler) {
          if (handler) handlers.set(action, handler); else handlers.delete(action);
          announce();
          return original.call(this, action, handler);
        },
      });
      Object.defineProperty(window, key, {
        value: (action) => { const handler = handlers.get(action); if (!handler) return false; handler({ action }); return true; },
      });
    })();
    """#

}

nonisolated extension BrowserMediaCommand {
    /// The script that runs the command, and the world it needs.
    var script: (source: String, world: BrowserScriptWorld) {
        let element = "const all = Array.from(document.querySelectorAll('video, audio')); "
            + "const e = all.find((m) => !m.paused && !m.ended) || all.find((m) => m.currentTime > 0) || all[0]; "
            + "if (!e) return false; "
        switch self {
        case .playPause:
            return ("(() => { \(element)if (e.paused) { e.play().catch(() => {}); } else { e.pause(); } return true; })()", .isolated)
        case .play:
            return ("(() => { \(element)e.play().catch(() => {}); return true; })()", .isolated)
        case .pause:
            return ("(() => { \(element)e.pause(); return true; })()", .isolated)
        case .toggleMute:
            return ("(() => { \(element)e.muted = !e.muted; return true; })()", .isolated)
        case .seek(let seconds):
            let to = seconds.isFinite ? max(0, seconds) : 0
            return ("(() => { \(element)e.currentTime = \(to); return true; })()", .isolated)
        case .muteTab(let on):
            return ("(() => { document.dispatchEvent(new CustomEvent('cmux-media-mute', { detail: \(on) })); return true; })()", .isolated)
        case .previousTrack:
            return ("(() => { const f = window[Symbol.for('cmux.mediaAction')]; return !!f && f('previoustrack'); })()", .page)
        case .nextTrack:
            return ("(() => { const f = window[Symbol.for('cmux.mediaAction')]; return !!f && f('nexttrack'); })()", .page)
        case .pictureInPicture:
            return (Self.pictureInPictureScript, .page)
        }
    }

    /// Picture in Picture's toggle, in the page's world: both engines run a
    /// page-world script as a user gesture, which `requestPictureInPicture`
    /// needs. A video that floats comes back; else the playing video (or
    /// one played, or the largest loaded one) of the page and its
    /// same-origin frames floats, through the standard API (Chromium, and
    /// WebKit where it has it) or WebKit's presentation mode. The page's own
    /// `disablePictureInPicture` holds. Answers a ``BrowserPictureInPicture``.
    static let pictureInPictureScript = #"""
    (() => {
      const docs = [document];
      for (let i = 0; i < frames.length; i++) { try { if (frames[i].document) docs.push(frames[i].document); } catch (_) {} }
      for (const d of docs) {
        if (d.pictureInPictureElement) { d.exitPictureInPicture().catch(() => {}); return 'exited'; }
      }
      const videos = docs.flatMap((d) => Array.from(d.querySelectorAll('video')));
      const shown = videos.find((v) => v.webkitPresentationMode === 'picture-in-picture');
      if (shown) { shown.webkitSetPresentationMode('inline'); return 'exited'; }
      const area = (v) => v.clientWidth * v.clientHeight;
      const v = videos.find((m) => !m.paused && !m.ended) || videos.find((m) => m.currentTime > 0 && !m.ended)
        || videos.filter((m) => m.readyState > 0).sort((a, b) => area(b) - area(a))[0];
      if (!v) return 'noVideo';
      if (v.disablePictureInPicture) return 'unsupported';
      if (v.ownerDocument.pictureInPictureEnabled && typeof v.requestPictureInPicture === 'function') {
        v.requestPictureInPicture().catch(() => {});
        return 'entered';
      }
      if (typeof v.webkitSupportsPresentationMode === 'function' && v.webkitSupportsPresentationMode('picture-in-picture')) {
        v.webkitSetPresentationMode('picture-in-picture');
        return 'entered';
      }
      return 'unsupported';
    })()
    """#
}

extension BrowserTab {
    /// Runs a media hub command in the page (`BrowserMediaCommand.script`).
    public func media(_ command: BrowserMediaCommand) async {
        let script = command.script
        _ = try? await evaluate(script.source, world: script.world)
    }

    /// Floats the page's video in Picture in Picture, or brings a floating
    /// one back (``BrowserMediaCommand/pictureInPicture``); nil when the
    /// page did not answer (closed, still loading).
    public func togglePictureInPicture() async -> BrowserPictureInPicture? {
        let script = BrowserMediaCommand.pictureInPicture.script
        guard case .string(let answer)? = try? await evaluate(script.source, world: script.world) else { return nil }
        return BrowserPictureInPicture(rawValue: answer)
    }

    /// After the page's media report: a document or frame that has not
    /// heard the tab's mute yet (a new page, a new frame) hears it now.
    func keepAudioMute(after report: BrowserMediaState?) {
        guard let report, report.isTabMuted != state.isAudioMuted else { return }
        // Sends the state when it runs, so a quick Mute then Unmute ends right.
        Task { await media(.muteTab(state.isAudioMuted)) }
    }
}
