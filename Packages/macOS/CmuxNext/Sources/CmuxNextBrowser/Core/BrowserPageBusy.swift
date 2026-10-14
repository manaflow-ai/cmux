import Foundation

/// What a page does that no element shows (cx-d0d.9): Web Audio and media capture. The
/// hibernation probe finds playing `<audio>`/`<video>` elements itself; a running
/// `AudioContext` or a `getDisplayMedia`/`getUserMedia` stream has no element, and the page's
/// own objects live in its world only. Chromium reports no capture state to the app
/// (`CEFTab.pageInfoInUse` is empty), so this is also how a Chromium tab's camera and
/// microphone are found. `recorderScript` runs in the page's world from document start in
/// every frame (both engines install it next to `BrowserMediaState.actionsScript`): it wraps
/// the `AudioContext` constructors, `getDisplayMedia` and `getUserMedia`, and keeps what they made. A child
/// frame tells its parent what it and its own children use, again when that changes, so the
/// top document answers for the tab. A page can see and replace the wrappers, which only
/// changes whether its own tab hibernates.
public nonisolated struct BrowserPageBusy: Equatable, Sendable {
    /// A running Web Audio context in the tab's frames.
    public var audio: Bool
    /// A live camera, microphone or screen capture track in the tab's frames.
    public var capturing: Bool

    public init(audio: Bool = false, capturing: Bool = false) {
        self.audio = audio
        self.capturing = capturing
    }

    static let recorderScript = #"""
    (() => {
      const key = Symbol.for('cmux.pageBusy');
      if (window[key]) return;
      // Contexts weakly: a page that makes one per sound and never closes them keeps none alive.
      const contexts = new Set(), streams = new Set(), children = new Map();
      const live = (stream) => stream.getTracks().some((t) => t.readyState === 'live');
      const busy = () => {
        const state = { audio: false, capturing: Array.from(streams).some(live) };
        for (const ref of contexts) {
          const context = ref.deref();
          if (!context || context.state === 'closed') { contexts.delete(ref); continue; }
          state.audio = state.audio || context.state === 'running';
        }
        for (const [frame, child] of children) {
          if (frame.closed) { children.delete(frame); continue; }
          state.audio = state.audio || child.audio;
          state.capturing = state.capturing || child.capturing;
        }
        return state;
      };
      let told = '';
      const post = (state) => {
        told = JSON.stringify(state);
        try { parent.postMessage({ cmuxPageBusy: state }, '*'); } catch (_) {}
      };
      const tell = () => {
        if (window === parent) return;
        const state = busy();
        if (JSON.stringify(state) !== told) post(state);
      };
      // Wrappers as proxies keep the originals' name, length and native toString.
      const wrap = (owner, name, handler) => {
        const original = owner ? owner[name] : null;
        if (typeof original === 'function') owner[name] = new Proxy(original, handler);
      };
      for (const name of ['AudioContext', 'webkitAudioContext']) {
        wrap(window, name, {
          construct(target, args, newTarget) {
            const context = Reflect.construct(target, args, newTarget);
            contexts.add(new WeakRef(context));
            context.addEventListener('statechange', tell);
            tell();
            return context;
          },
        });
      }
      const devices = typeof MediaDevices === 'function' ? MediaDevices.prototype : null;
      for (const name of ['getDisplayMedia', 'getUserMedia']) {
        wrap(devices, name, {
          apply(target, self, args) {
            return Reflect.apply(target, self, args).then((stream) => {
              streams.add(stream);
              for (const track of stream.getTracks()) {
                track.addEventListener('ended', () => { if (!live(stream)) streams.delete(stream); tell(); });
              }
              tell();
              return stream;
            });
          },
        });
      }
      // A track the page stops fires no 'ended'.
      wrap(typeof MediaStreamTrack === 'function' ? MediaStreamTrack.prototype : null, 'stop', {
        apply(target, self, args) {
          const result = Reflect.apply(target, self, args);
          for (const stream of streams) { if (!live(stream)) streams.delete(stream); }
          tell();
          return result;
        },
      });
      addEventListener('message', (event) => {
        const data = event.data, from = event.source;
        if (!data || typeof data.cmuxPageBusy !== 'object' || !from) return;
        let child = false;
        for (let i = 0; i < frames.length; i++) { if (frames[i] === from) { child = true; break; } }
        if (!child) return;
        children.set(from, { audio: data.cmuxPageBusy.audio === true, capturing: data.cmuxPageBusy.capturing === true });
        tell();
      });
      // A frame that navigates keeps its window: its new document reports at once, and the
      // old one clears its report when it goes.
      if (window !== parent) {
        post(busy());
        addEventListener('pagehide', () => post({ audio: false, capturing: false }));
      }
      Object.defineProperty(window, key, { value: busy });
    })();
    """#

    /// The probe's question, in the page's world: `{"audio": Bool, "capturing": Bool}` as JSON,
    /// `{}` when the recorder is missing (a page loaded before it was installed).
    static let probeScript = "(() => { const f = window[Symbol.for('cmux.pageBusy')]; return JSON.stringify(f ? f() : {}); })()"
}

extension BrowserTab {
    /// Asks the page's recorder (`BrowserPageBusy`). Throws when the page does not answer.
    public func pageBusy() async throws -> BrowserPageBusy {
        let value = try await evaluate(BrowserPageBusy.probeScript, world: .page)
        guard case .string(let json) = value, let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return BrowserPageBusy(audio: object["audio"] as? Bool ?? false, capturing: object["capturing"] as? Bool ?? false)
    }
}
