#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its page view.
import AppKit

/// Host mode: the word under a force click or three-finger tap for the page view's Look Up (task
/// 054 of plans/cmux-next/chrome-parity/p01-process.md). Chrome's page view sends
/// `LookUpDictionaryOverlayAtPoint` and its browser process asks the renderer for the word there
/// (`TextInputClientMac::GetStringAtPoint`, Blink's word at point), then answers with
/// `ShowDictionaryOverlay`. CEF has no word-at-point call, so the renderer answers the same question
/// from the page's own layout, in cmux's isolated world, over the shim's evaluate (one question at a
/// time: ``CEFRuntime/evaluateLatest(_:world:script:done:)``).
extension CEFPaneHost {
    /// Asks the shown tab's page for the word at `point` (top-left page points; `scale` the window's
    /// backing scale, so the page's zoom is `devicePixelRatio / scale`); `answered` gets nil with no
    /// shown page, no word there, or no evaluate in the shim.
    func lookUpWord(at point: CGPoint, scale: CGFloat, answered: @escaping (ChromiumHostLookUpWord?) -> Void) {
        guard let browser = visibleTab?.browserID else { return answered(nil) }
        runtime.evaluateLatest(browser, world: "cmux", script: ChromiumHostLookUpWord.script(at: point, scale: scale)) { result in
            answered(result.flatMap(ChromiumHostLookUpWord.init(result:)))
        }
    }
}
#endif
