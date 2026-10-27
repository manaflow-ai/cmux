import CmuxNextCompat
import Foundation

// The probe's scripts and the tab calls that run them (`BrowserPageBusy` describes what the recorder keeps).
nonisolated extension BrowserPageBusy {
    /// Unmuted media playing or a video in Picture in Picture (it plays on in
    /// its floating window; `media`), unmuted media playing alone (`sound`), or
    /// form fields whose value differs from the page's default (form interaction):
    /// the fallback for a page without the recorder.
    /// A page that does not answer within the deadline is treated as busy and kept.
    package static let fieldProbeScript = """
    (() => {
      const sound = [...document.querySelectorAll('audio,video')].some(m => !m.paused && !m.ended && !m.muted && m.volume > 0);
      const media = sound || !!document.pictureInPictureElement
        || [...document.querySelectorAll('video')].some(v => v.webkitPresentationMode === 'picture-in-picture');
      const form = [...document.querySelectorAll('input,textarea,select')].some(e => {
        if (e.disabled || e.type === 'hidden' || e.type === 'submit' || e.type === 'button') return false;
        if (e.tagName === 'SELECT') return [...e.options].some(o => o.selected !== o.defaultSelected);
        if (e.type === 'checkbox' || e.type === 'radio') return e.checked !== e.defaultChecked;
        return e.value !== e.defaultValue;
      });
      return JSON.stringify({media, sound, form});
    })()
    """

    /// The probe's question, in the page's world: `{"audio", "capturing", "form", "unload", "handler", "rtc", "device",
    /// "opaque", "lock", "idb"}` (Bools) as JSON, `{}` when the recorder is missing (a page loaded before it was installed). It runs
    /// no page code.
    static let probeScript = "(() => { const f = window[Symbol.for('cmux.pageBusy')]; return JSON.stringify(f ? f() : {}); })()"

    /// Runs the top document's beforeunload handlers, as a close would, and answers whether one
    /// cancels (`preventDefault()`, a `returnValue`, or an `onbeforeunload` that returns a message):
    /// `true`/`false`, or `null` when the recorder is missing. Page code runs: see `BrowserTab.asksBeforeUnload()`.
    static let askScript = "(() => { const f = window[Symbol.for('cmux.pageBusy.asks')]; return f ? f() : null; })()"
}

extension BrowserTab {
    /// Asks the page's recorder (`BrowserPageBusy`); runs no page code and no user gesture
    /// (`BrowserScriptGesture.cmux`), so the probe never counts as the person's activation. Throws
    /// when the page does not answer, or `unsupported` where the engine cannot run a script without
    /// a gesture (the probe then counts as unanswered: the page stays awake).
    public func pageBusy() async throws -> BrowserPageBusy {
        let value = try await evaluate(BrowserPageBusy.probeScript, world: .page, gesture: .cmux)
        guard case .string(let json) = value, let data = json.data(using: .utf8),
              let object = try JSONSerialization.blockingJSONObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return BrowserPageBusy(audio: object["audio"] as? Bool ?? false, capturing: object["capturing"] as? Bool ?? false,
                               editedForm: object["form"] as? Bool, beforeUnload: object["unload"] as? Bool ?? false,
                               unloadHandler: object["handler"] as? Bool ?? false,
                               webRTC: object["rtc"] as? Bool ?? false, connectedDevice: object["device"] as? Bool ?? false,
                               unreadableFrame: object["opaque"] as? Bool ?? false,
                               webLock: object["lock"] as? Bool ?? false, indexedDB: object["idb"] as? Bool ?? false)
    }

    /// Runs the top document's beforeunload handlers, as a close would, and answers whether the page
    /// would ask ("Leave site?"). Page code runs (a handler may close a socket or send a beacon), so
    /// the caller asks only right before it discards the page, and at most once while it stays
    /// hidden. It runs without a user gesture: a handler cannot open a popup on cmux's behalf or see
    /// the person's activation.
    /// - Throws: `BrowserTabError.unsupported` when the engine cannot run a script without a user
    ///   gesture, or when the page has no recorder; the page's own errors.
    public func asksBeforeUnload() async throws -> Bool {
        guard case .bool(let asks) = try await evaluate(BrowserPageBusy.askScript, world: .page, gesture: .cmux) else {
            throw BrowserTabError.unsupported("no page recorder")
        }
        return asks
    }
}
