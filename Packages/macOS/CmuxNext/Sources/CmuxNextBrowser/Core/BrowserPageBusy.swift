import Foundation

/// What a page does that no element shows (cx-d0d.9): Web Audio and media capture, and form
/// fields the person changed. The
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
///
/// Form edits (`form`), each in the document's own frame:
/// - a field the person changed (a trusted `input` or `change`) that still differs from its default;
/// - after the person first used the document (a trusted key, pointer, click, paste or drop), any
///   field that differs from its default and from what it held at that moment, so a value a widget
///   or the page's script set for the person (a date picker, a Select2 menu, a re-rendered draft)
///   counts, and the values the script filled at load do not. A recorder installed after the page
///   was used (Chromium attaches late) has no such moment and compares with the defaults only;
/// - a rich editor (`contenteditable`) the person typed in whose text differs from what it held
///   when they started, while it is in the document (a composer cleared by a send does not count).
/// A document nobody used whose script fills fields (a docs site's version menu, a wiki's appearance
/// radios, a `<select>` with no default option) hibernates; those used to stay loaded forever (the
/// 2026-10-14 hibernation audit: 7 of 20 sites, about 85 MB of renderer each).
public nonisolated struct BrowserPageBusy: Equatable, Sendable {
    /// A running Web Audio context in the tab's frames.
    public var audio: Bool
    /// A live camera, microphone or screen capture track in the tab's frames.
    public var capturing: Bool
    /// The person's form edits in the tab's frames (see above); nil when the page's recorder did not
    /// answer (the probe then compares every field with its default, as before the recorder).
    public var editedForm: Bool?

    public init(audio: Bool = false, capturing: Bool = false, editedForm: Bool? = nil) {
        self.audio = audio
        self.capturing = capturing
        self.editedForm = editedForm
    }

    /// Unmuted media playing or a video in Picture in Picture (it plays on in
    /// its floating window), a running Web Audio context, a live camera,
    /// microphone or screen capture, or form fields whose value differs from the
    /// page's default (form interaction): the fallback for a page without the recorder.
    /// A page that does not answer within the deadline is treated as busy and kept.
    package static let fieldProbeScript = """
    (() => {
      const differs = \(differsFromDefault);
      const media = [...document.querySelectorAll('audio,video')].some(m => !m.paused && !m.ended && !m.muted && m.volume > 0)
        || !!document.pictureInPictureElement
        || [...document.querySelectorAll('video')].some(v => v.webkitPresentationMode === 'picture-in-picture');
      const form = [...document.querySelectorAll('input,textarea,select')].some(e => {
        if (e.disabled || e.type === 'hidden' || e.type === 'submit' || e.type === 'button') return false;
        return differs(e);
      });
      return JSON.stringify({media, form});
    })()
    """

    /// Whether a form field's value differs from what its markup gives it, as a JS function. A
    /// one-line `<select>` with no default option shows its first enabled option (HTML's
    /// selectedness setting; an option in a disabled `<optgroup>` is not enabled, which the
    /// option's own `disabled` does not show), so that option is its default; comparing each
    /// option's `selected` with `defaultSelected` called every such menu edited (the 2026-10-23
    /// light bench: a Chromium page whose recorder attached late kept its page as form input).
    /// Shared by ``fieldProbeScript`` and ``recorderScript``.
    static let differsFromDefault = """
    (e) => {
      if (e.tagName === 'SELECT') {
        const options = Array.from(e.options);
        if (e.multiple || e.size > 1) return options.some((o) => o.selected !== o.defaultSelected);
        const enabled = (o) => !o.disabled && !(o.parentElement?.tagName === 'OPTGROUP' && o.parentElement.disabled);
        let shown = -1;
        options.forEach((o, i) => { if (o.defaultSelected) shown = i; });
        if (shown < 0) shown = options.findIndex(enabled);
        return e.selectedIndex !== shown;
      }
      if (e.type === 'checkbox' || e.type === 'radio') return e.checked !== e.defaultChecked;
      return e.value !== e.defaultValue;
    }
    """

    static let recorderScript = #"""
    (() => {
      const key = Symbol.for('cmux.pageBusy');
      if (window[key]) return;
      // Contexts weakly: a page that makes one per sound and never closes them keeps none alive.
      const contexts = new Set(), streams = new Set(), children = new Map(), fields = new Set(), seen = new WeakSet();
      // Editing hosts weakly, with the text each held when the person started typing in it.
      const editors = new Set(), started = new WeakMap();
      const live = (stream) => stream.getTracks().some((t) => t.readyState === 'live');
      // Fields' values at the person's first use; installed after a use (Chromium attaches late):
      // none, every field is compared with its default.
      let used = navigator.userActivation?.hasBeenActive === true, baseline = null;
      const all = () => Array.from(document.querySelectorAll('input,textarea,select')).filter((e) =>
        !e.disabled && e.type !== 'hidden' && e.type !== 'submit' && e.type !== 'button');
      const current = (e) => e.tagName === 'SELECT' ? Array.from(e.options).map((o) => o.selected).join()
        : e.type === 'checkbox' || e.type === 'radio' ? String(e.checked) : e.value;
      const differs = \#(differsFromDefault);
      const changed = (e) => e.isConnected && !e.disabled && differs(e);
      const busy = () => {
        const state = { audio: false, capturing: Array.from(streams).some(live), form: false };
        for (const ref of fields) {
          const field = ref.deref();
          if (!field) { fields.delete(ref); continue; }
          state.form = state.form || changed(field);
        }
        for (const ref of editors) {
          const host = ref.deref();
          if (!host) { editors.delete(ref); continue; }
          state.form = state.form || (host.isConnected && host.textContent !== started.get(host));
        }
        if (used && !state.form) {
          state.form = all().some((e) => changed(e) && (!baseline || !baseline.has(e) || baseline.get(e) !== current(e)));
        }
        for (const ref of contexts) {
          const context = ref.deref();
          if (!context || context.state === 'closed') { contexts.delete(ref); continue; }
          state.audio = state.audio || context.state === 'running';
        }
        for (const [frame, child] of children) {
          if (frame.closed) { children.delete(frame); continue; }
          state.audio = state.audio || child.audio;
          state.capturing = state.capturing || child.capturing;
          state.form = state.form || child.form;
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
      // Only the person's edits (trusted events); fields weakly, like the contexts.
      const edit = (event) => {
        let field = event.isTrusted ? event.composedPath()[0] : null;
        if (field instanceof HTMLInputElement || field instanceof HTMLTextAreaElement || field instanceof HTMLSelectElement) {
          if (event.type === 'beforeinput') return;
          if (!seen.has(field)) { seen.add(field); fields.add(new WeakRef(field)); }
        } else if (field instanceof HTMLElement && field.isContentEditable) {
          while (field.parentElement?.isContentEditable) field = field.parentElement;
          if (!started.has(field)) {
            // Its text before this edit (an input without a beforeinput: it was empty).
            started.set(field, event.type === 'beforeinput' ? field.textContent : '');
            editors.add(new WeakRef(field));
          }
        } else return;
        tell();
      };
      const use = (event) => {
        if (!event.isTrusted || used) return;
        used = true;
        baseline = new Map(all().map((e) => [e, current(e)]));
        tell();
      };
      for (const type of ['keydown', 'pointerdown', 'mousedown', 'click', 'paste', 'drop']) addEventListener(type, use, true);
      for (const type of ['beforeinput', 'input', 'change']) addEventListener(type, edit, true);
      addEventListener('message', (event) => {
        const data = event.data, from = event.source;
        if (!data || typeof data.cmuxPageBusy !== 'object' || !from) return;
        let child = false;
        for (let i = 0; i < frames.length; i++) { if (frames[i] === from) { child = true; break; } }
        if (!child) return;
        const report = data.cmuxPageBusy;
        children.set(from, { audio: report.audio === true, capturing: report.capturing === true, form: report.form === true });
        tell();
      });
      // A frame that navigates keeps its window: its new document reports at once, and the
      // old one clears its report when it goes.
      if (window !== parent) {
        post(busy());
        addEventListener('pagehide', () => post({ audio: false, capturing: false, form: false }));
      }
      Object.defineProperty(window, key, { value: busy });
    })();
    """#

    /// The probe's question, in the page's world: `{"audio": Bool, "capturing": Bool, "form": Bool}` as JSON,
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
        return BrowserPageBusy(audio: object["audio"] as? Bool ?? false, capturing: object["capturing"] as? Bool ?? false,
                               editedForm: object["form"] as? Bool)
    }
}
