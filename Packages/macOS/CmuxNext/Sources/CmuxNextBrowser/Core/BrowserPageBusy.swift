import CmuxNextCompat
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
/// `beforeunload`: the probe runs no page code. It reads the recorder's own record: whether the
/// person used the top document and it has a handler (`handler`; the wrapped `addEventListener` and
/// `onbeforeunload` setter keep it). Chromium and WebKit ask only after the person used the document,
/// so a document nobody used never asks. A child frame cannot be asked from the top (it may be
/// cross-origin), so it reports whether it has a handler and the person used it; that counts as
/// asking (`unload`). Whether the top document's handlers would really ask is learned only by
/// running them (`askScript`): the hibernation does that once per hidden period, without a user
/// gesture, as the last step right before a discard and only when nothing else keeps the page, so a
/// page that stays has not had its unload logic run behind the person's back on every probe.
///
/// WebRTC (`rtc`): the recorder wraps the `RTCPeerConnection` constructors and reports a connected one.
///
/// Devices (`device`): each `open()` of a `USBDevice`, `HIDDevice` or `SerialPort` and each `connect()`
/// of a `BluetoothRemoteGATTServer` keeps the object weakly; the probe asks whether it is still open
/// (Chrome keeps such tabs: kConnectedToUSB, kConnectedToBluetooth). Chromium only.
///
/// Unreadable frames (`opaque`): when the person moves into a child frame that never reported (it has
/// no recorder: Chromium's cross-origin frames get none from the DevTools script), the window blurs
/// with the person's transient activation and the frame element is kept; while it is in the document
/// and still silent, its edits are unknown and count as the person's input.
///
/// Web Locks and IndexedDB (`lock`, `idb`): the recorder counts the locks this document was granted
/// and holds (a `request` callback whose promise has not settled) and the IndexedDB connections it
/// opened and has not closed, as Chrome counts them per frame (kHoldingWebLock, and
/// kHoldingBlockingIndexedDBLock for which an open connection stands in). `navigator.locks.query()`
/// would list every page of the origin, not this one. Only a freeze checks them.
///
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
    /// A child frame the person used has a `beforeunload` handler: the tab would ask before it
    /// unloads ("Leave site?"; see above).
    public var beforeUnload: Bool
    /// The person used the top document and it has a `beforeunload` handler: it may ask. Only
    /// `BrowserTab.asksBeforeUnload()` says whether, by running the handlers.
    public var unloadHandler: Bool
    /// A connected `RTCPeerConnection` in the tab's frames.
    public var webRTC: Bool
    /// An open USB, HID or serial device, or a connected Bluetooth GATT server, in the tab's frames.
    public var connectedDevice: Bool
    /// The person moved into a child frame the recorder cannot read (no recorder in it: Chromium's
    /// cross-origin frames), still in the document.
    public var unreadableFrame: Bool
    /// A Web Lock held in the tab's frames.
    public var webLock: Bool
    /// An open IndexedDB connection in the tab's frames.
    public var indexedDB: Bool

    public init(audio: Bool = false, capturing: Bool = false, editedForm: Bool? = nil, beforeUnload: Bool = false,
                unloadHandler: Bool = false, webRTC: Bool = false, connectedDevice: Bool = false, unreadableFrame: Bool = false,
                webLock: Bool = false, indexedDB: Bool = false) {
        self.audio = audio
        self.capturing = capturing
        self.editedForm = editedForm
        self.beforeUnload = beforeUnload
        self.unloadHandler = unloadHandler
        self.webRTC = webRTC
        self.connectedDevice = connectedDevice
        self.unreadableFrame = unreadableFrame
        self.webLock = webLock
        self.indexedDB = indexedDB
    }

    static let recorderScript = #"""
    (() => {
      const key = Symbol.for('cmux.pageBusy');
      if (window[key]) return;
      // Contexts weakly: a page that makes one per sound and never closes them keeps none alive.
      const contexts = new Set(), streams = new Set(), children = new Map(), fields = new Set(), seen = new WeakSet();
      // Peer connections weakly; this window's beforeunload listeners, each with its capture flags.
      const peers = new Set(), unloadListeners = new Map();
      // Devices the page opened (USB, HID, serial, Bluetooth GATT), weakly; child frame elements the
      // person activated that never reported (no recorder in them), weakly.
      const heldDevices = new Set(), seenDevices = new WeakSet(), opaque = new Set(), seenFrames = new WeakSet();
      // Editing hosts weakly, with the text each held when the person started typing in it.
      const editors = new Set(), started = new WeakMap();
      // Web Locks granted and not yet released; IndexedDB connections weakly, and those closed.
      let locks = 0;
      const databases = new Set(), closedDatabases = new WeakSet();
      const live = (stream) => stream.getTracks().some((t) => t.readyState === 'live');
      // Fields' values at the person's first use; installed after a use (Chromium attaches late):
      // none, every field is compared with its default.
      let used = navigator.userActivation?.hasBeenActive === true, baseline = null;
      const all = () => Array.from(document.querySelectorAll('input,textarea,select')).filter((e) =>
        !e.disabled && e.type !== 'hidden' && e.type !== 'submit' && e.type !== 'button');
      const current = (e) => e.tagName === 'SELECT' ? Array.from(e.options).map((o) => o.selected).join()
        : e.type === 'checkbox' || e.type === 'radio' ? String(e.checked) : e.value;
      const changed = (e) => {
        if (!e.isConnected || e.disabled) return false;
        if (e.tagName === 'SELECT') return Array.from(e.options).some((o) => o.selected !== o.defaultSelected);
        if (e.type === 'checkbox' || e.type === 'radio') return e.checked !== e.defaultChecked;
        return e.value !== e.defaultValue;
      };
      // The person used this document: a trusted key, pointer, click, paste or drop (or, for a recorder
      // installed late, sticky activation at install). Not `navigator.userActivation` now: cmux's own
      // script calls run with a user gesture in both engines, so every probe would count as a use.
      const activated = () => used;
      // Whether this document would ask before it unloads: its beforeunload handlers run, as for a close.
      // Only `askScript` calls it; the probe itself never runs page code.
      const asks = () => {
        if (!activated()) return false;
        let event;
        try { event = document.createEvent('BeforeUnloadEvent'); } catch (_) { return false; }
        event.initEvent('beforeunload', false, true);
        dispatchEvent(event);
        return event.defaultPrevented || !!event.returnValue;
      };
      const hasUnloadHandler = () => activated() && (unloadListeners.size > 0 || typeof window.onbeforeunload === 'function');
      // `unload`: a child frame would ask; `handler`: this document may ask (`asks` says whether).
      const busy = () => {
        const state = { audio: false, capturing: Array.from(streams).some(live), form: false,
                        unload: false, handler: hasUnloadHandler(), rtc: false, device: false, opaque: false,
                        lock: locks > 0, idb: false };
        for (const ref of databases) {
          const database = ref.deref();
          if (!database || closedDatabases.has(database)) { databases.delete(ref); continue; }
          state.idb = true;
        }
        for (const entry of heldDevices) {
          const handle = entry.ref.deref();
          if (!handle) { heldDevices.delete(entry); continue; }
          state.device = state.device || entry.isOpen(handle);
        }
        for (const ref of opaque) {
          const frame = ref.deref();
          if (!frame || !frame.isConnected) { opaque.delete(ref); continue; }
          const view = frame.contentWindow;
          state.opaque = state.opaque || (!!view && !children.has(view));
        }
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
        for (const ref of peers) {
          const peer = ref.deref();
          if (!peer || peer.connectionState === 'closed') { peers.delete(ref); continue; }
          state.rtc = state.rtc || peer.connectionState === 'connected';
        }
        for (const [frame, child] of children) {
          if (frame.closed) { children.delete(frame); continue; }
          state.audio = state.audio || child.audio;
          state.capturing = state.capturing || child.capturing;
          state.form = state.form || child.form;
          state.unload = state.unload || child.unload;
          state.rtc = state.rtc || child.rtc;
          state.device = state.device || child.device;
          state.opaque = state.opaque || child.opaque;
          state.lock = state.lock || child.lock;
          state.idb = state.idb || child.idb;
        }
        return state;
      };
      let told = '';
      // A child frame's own handler counts as asking for the top (it cannot be asked from there).
      const report = () => {
        const state = busy();
        return { audio: state.audio, capturing: state.capturing, form: state.form, unload: state.unload || state.handler,
                 rtc: state.rtc, device: state.device, opaque: state.opaque, lock: state.lock, idb: state.idb };
      };
      const post = (state) => {
        told = JSON.stringify(state);
        try { parent.postMessage({ cmuxPageBusy: state }, '*'); } catch (_) {}
      };
      const tell = () => {
        if (window === parent) return;
        const state = report();
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
      for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
        wrap(window, name, {
          construct(target, args, newTarget) {
            const peer = Reflect.construct(target, args, newTarget);
            peers.add(new WeakRef(peer));
            peer.addEventListener('connectionstatechange', tell);
            return peer;
          },
        });
      }
      // A lock is held from its grant (the callback runs with it) until the callback's promise settles;
      // an `ifAvailable` request that got none runs the callback with null.
      wrap(typeof LockManager === 'function' ? LockManager.prototype : null, 'request', {
        apply(target, self, args) {
          const last = args.length - 1, callback = args[last];
          if (typeof callback !== 'function') return Reflect.apply(target, self, args);
          const granted = (lock) => {
            if (!lock) return callback(lock);
            locks++;
            tell();
            const release = () => { locks--; tell(); };
            let result;
            try { result = callback(lock); } catch (error) { release(); throw error; }
            Promise.resolve(result).then(release, release);
            return result;
          };
          return Reflect.apply(target, self, [...args.slice(0, last), granted]);
        },
      });
      const closeDatabase = (database) => { closedDatabases.add(database); tell(); };
      wrap(typeof IDBDatabase === 'function' ? IDBDatabase.prototype : null, 'close', {
        apply(target, self, args) {
          const result = Reflect.apply(target, self, args);
          if (self) closeDatabase(self);
          return result;
        },
      });
      wrap(typeof IDBFactory === 'function' ? IDBFactory.prototype : null, 'open', {
        apply(target, self, args) {
          const request = Reflect.apply(target, self, args);
          request.addEventListener('success', () => {
            const database = request.result;
            databases.add(new WeakRef(database));
            database.addEventListener('close', () => closeDatabase(database));
            tell();
          });
          return request;
        },
      });
      // A device connection the page holds (Chrome keeps such tabs: kConnectedToUSB,
      // kConnectedToBluetooth): each open() or connect() keeps the object; the probe asks whether
      // it is still open. Chromium only; WebKit has none of these interfaces.
      const device = (name, open, close, isOpen) => {
        const proto = typeof window[name] === 'function' ? window[name].prototype : null;
        // A close changes a child frame's report.
        wrap(proto, close, {
          apply(target, self, args) {
            const result = Reflect.apply(target, self, args);
            if (result && typeof result.then === 'function') result.then(tell, tell); else tell();
            return result;
          },
        });
        wrap(proto, open, {
          apply(target, self, args) {
            const result = Reflect.apply(target, self, args);
            const keep = () => {
              if (self && !seenDevices.has(self)) { seenDevices.add(self); heldDevices.add({ ref: new WeakRef(self), isOpen }); }
              tell();
            };
            if (result && typeof result.then === 'function') result.then(keep, () => {}); else keep();
            return result;
          },
        });
      };
      device('USBDevice', 'open', 'close', (d) => d.opened === true);
      device('HIDDevice', 'open', 'close', (d) => d.opened === true);
      device('SerialPort', 'open', 'close', (p) => !!(p.readable || p.writable));
      device('BluetoothRemoteGATTServer', 'connect', 'disconnect', (g) => g.connected === true);
      // The person moved into a child frame that has no recorder (Chromium's cross-origin frames
      // get none from the DevTools script): its fields cannot be read, so it counts as holding
      // the person's input while it is in the document. Activation reaches the parent's window
      // too, so a frame the page focuses by itself does not count (unless a cmux script call,
      // which carries a gesture, ran in the last seconds: then the page is kept, the safe side).
      addEventListener('blur', (event) => {
        if (event.target !== window) return;
        const frame = document.activeElement;
        if (!frame || (frame.tagName !== 'IFRAME' && frame.tagName !== 'FRAME') || seenFrames.has(frame)) return;
        if (navigator.userActivation?.isActive !== true) return;
        seenFrames.add(frame);
        opaque.add(new WeakRef(frame));
        tell();
      }, true);
      // This window's own beforeunload listeners (a child frame reports whether it has one).
      for (const [name, add] of [['addEventListener', true], ['removeEventListener', false]]) {
        wrap(window, name, {
          apply(target, self, args) {
            const result = Reflect.apply(target, self, args);
            const listener = args[1];
            if ((self ?? window) === window && args[0] === 'beforeunload' && listener) {
              const capture = typeof args[2] === 'boolean' ? args[2] : !!args[2]?.capture;
              const captures = unloadListeners.get(listener) ?? new Set();
              if (add) captures.add(capture); else captures.delete(capture);
              if (captures.size) unloadListeners.set(listener, captures); else unloadListeners.delete(listener);
              tell();
            }
            return result;
          },
        });
      }
      // A handler set through the property after the person's first use is reported too.
      for (let owner = window; owner; owner = Object.getPrototypeOf(owner)) {
        const property = Object.getOwnPropertyDescriptor(owner, 'onbeforeunload');
        if (!property) continue;
        if (property.set && property.configurable) {
          Object.defineProperty(window, 'onbeforeunload', { ...property, set(value) { property.set.call(this, value); tell(); } });
        }
        break;
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
        children.set(from, { audio: report.audio === true, capturing: report.capturing === true, form: report.form === true,
                             unload: report.unload === true, rtc: report.rtc === true, device: report.device === true,
                             opaque: report.opaque === true, lock: report.lock === true, idb: report.idb === true });
        tell();
      });
      // A frame that navigates keeps its window: its new document reports at once, and the
      // old one clears its report when it goes.
      if (window !== parent) {
        post(report());
        addEventListener('pagehide', () => post({ audio: false, capturing: false, form: false, unload: false, rtc: false,
                                                  device: false, opaque: false, lock: false, idb: false }));
      }
      Object.defineProperty(window, key, { value: busy });
      Object.defineProperty(window, Symbol.for('cmux.pageBusy.asks'), { value: asks });
    })();
    """#
}
