import Foundation

/// The page scripts behind the media hub (cx-6qwm.2), the same in both
/// engines; no engine API reports media. `observerScript` runs in an isolated
/// world from document start in every frame: it watches media elements
/// (their events, in the capture phase) and `navigator.mediaSession`, and
/// posts a report when what plays changes, null once nothing does. A frame
/// that never played posts nothing, so a page's frames do not clear each
/// other. `actionsScript` runs in the page's world: it records the page's
/// `mediaSession` action handlers so Previous and Next can call them
/// (handlers live in the page's world only); a page can see that wrapper,
/// so those two are best effort. Media elements outside the document (a
/// detached `new Audio()`) are not seen. A `cmux-media-mute` event mutes
/// (or unmutes) the frame's media elements, keeps muting the ones that play
/// next, and passes on to the frame's child frames.
nonisolated extension BrowserMediaState {
    /// WebKit's message handler and Chromium's binding.
    static let channel = "cmuxMedia"
    /// The isolated world the observer runs in.
    static let world = "cmux-media"

    /// The observer, posting with `post` (a JS expression taking the report)
    /// once `ready` (a JS expression) is true.
    static func observerScript(post: String, ready: String = "true") -> String {
        #"""
        (() => {
          if (window.__cmuxMedia) return;
          window.__cmuxMedia = true;
          let last = '', reported = false, pending = false, heartbeat = false, timer = 0, actions = '', tabMuted = false;
          // The elements the tab's mute muted, which Unmute unmutes.
          const hushed = new WeakSet();
          const media = (e) => !!e && (e.tagName === 'VIDEO' || e.tagName === 'AUDIO');
          const hush = (e) => { if (tabMuted && !e.muted) { e.muted = true; hushed.add(e); } };
          const send = (report) => {
            if (!(\#(ready))) { pending = true; return false; }
            pending = false;
            try { \#(post); return true; } catch (_) { return false; }
          };
          const active = () => {
            const all = Array.from(document.querySelectorAll('video, audio'));
            return all.find((e) => !e.paused && !e.ended) || all.find((e) => e.currentTime > 0 && !e.ended) || null;
          };
          const artwork = (meta) => {
            const list = meta && meta.artwork ? Array.from(meta.artwork) : [];
            const best = list[list.length - 1];
            try { return best ? new URL(best.src, location.href).href : ''; } catch (_) { return ''; }
          };
          const report = () => {
            timer = 0;
            const element = active();
            if (!element) {
              if (reported && send(null)) { reported = false; last = ''; }
              return;
            }
            const meta = navigator.mediaSession ? navigator.mediaSession.metadata : null;
            const state = {
              title: (meta && meta.title) || document.title || '',
              artist: (meta && meta.artist) || '', album: (meta && meta.album) || '',
              artwork: artwork(meta), playing: !element.paused && !element.ended,
              muted: element.muted || element.volume === 0, video: element.tagName === 'VIDEO', tabMuted, actions,
            };
            const key = JSON.stringify(state);
            // Again every few seconds while it plays: another frame's
            // report may have replaced it.
            if (key === last && !heartbeat) return;
            if (!send(state)) return;
            last = key;
            reported = true;
          };
          const schedule = () => { if (!timer) timer = setTimeout(report, 250); };
          for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange', 'loadedmetadata']) {
            addEventListener(type, schedule, true);
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
          addEventListener('message', (event) => {
            const data = event.data;
            if (window !== top && data && typeof data.cmuxMediaMute === 'boolean') muteTab(data.cmuxMediaMute);
          });
          document.addEventListener('cmux-media-actions', (event) => {
            actions = typeof event.detail === 'string' ? event.detail : '';
            schedule();
          }, true);
          // Metadata changes fire no event: look again while something
          // plays, and retry a report the binding was not ready for.
          let ticks = 0;
          setInterval(() => {
            ticks += 1;
            heartbeat = reported && ticks % 3 === 0;
            if (reported || pending) schedule();
          }, 1000);
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
        case .toggleMute:
            return ("(() => { \(element)e.muted = !e.muted; return true; })()", .isolated)
        case .muteTab(let on):
            return ("(() => { document.dispatchEvent(new CustomEvent('cmux-media-mute', { detail: \(on) })); return true; })()", .isolated)
        case .previousTrack:
            return ("(() => { const f = window[Symbol.for('cmux.mediaAction')]; return !!f && f('previoustrack'); })()", .page)
        case .nextTrack:
            return ("(() => { const f = window[Symbol.for('cmux.mediaAction')]; return !!f && f('nexttrack'); })()", .page)
        }
    }
}

extension BrowserTab {
    /// Runs a media hub command in the page (`BrowserMediaCommand.script`).
    public func media(_ command: BrowserMediaCommand) async {
        let script = command.script
        _ = try? await evaluate(script.source, world: script.world)
    }

    /// After the page's media report: a document or frame that has not
    /// heard the tab's mute yet (a new page, a new frame) hears it now.
    func keepAudioMute(after report: BrowserMediaState?) {
        guard let report, report.isTabMuted != state.isAudioMuted else { return }
        let muted = state.isAudioMuted
        Task { await media(.muteTab(muted)) }
    }
}
