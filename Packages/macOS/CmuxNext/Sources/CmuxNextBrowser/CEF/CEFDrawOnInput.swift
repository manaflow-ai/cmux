import CmuxNextDesign
import Foundation

/// Agent chat pages draw a key's frame at once (fork API 35, `cmux_browser_set_draw_on_input`).
///
/// While a chat's reply streams, its page window's display is already ticking, so Chromium draws a key's change at
/// the next vsync's BeginFrame: 0 to 16.7 ms at 60 Hz after the page handled the key, which no page-side change
/// removes (chat-typing-while-streaming: latency + phase = one interval in 26 of 30 keys). With this on, the fork asks
/// the page window's display for a BeginFrame as soon as the page acknowledges each key event, in place of the next
/// vsync's: the page draws no more frames per second, and nothing runs while it is idle (Leo, 2026-11-17: "we're not
/// waiting for ui to render. we're just gonna have the text be drawn fast").
///
/// Behind Debug Settings > Browser Page Loading > "Draw keys at once in agent chats" (``setting``), off by default,
/// and only with an engine at fork API ``forkAPI`` or later; an older engine makes no call. The fork follows a tab's
/// page across navigations, so a browser is opted in once, when its address first is an agent chat's
/// (``addressChanged(browser:url:)``), and out when it leaves for another page or the setting turns off.
@MainActor
final class CEFDrawOnInput {
    /// The first fork version with `cmux_browser_set_draw_on_input` (CMUX-API.md row 35).
    static let forkAPI: Int32 = 35

    /// Debug Settings > Browser Page Loading (`BrowserPageTunables.all`). Off by default until its numbers beat
    /// 8 ms p95 while a reply streams on the typing bench (scripts/cmux-next/typing-frame-bench.py).
    nonisolated static let setting = Tunable<Bool>.toggle(
        "browserPage.drawKeysAtOnce", BrowserPageTunables.section, "Draw keys at once in agent chats",
        help: "An agent chat page asks Chromium for its next frame as soon as it has handled a key, instead of waiting for the next display refresh (up to 16.7 ms at 60 Hz) while its reply streams. The frame replaces that refresh's frame, so the page draws no more often. Needs a Chromium engine with fork API 35.",
        default: false, code: "CEFDrawOnInput.setting")

    /// `cmux_shim_browser_set_draw_on_input(browser, enabled)`: true when the fork took it. Nil without a shim, a
    /// shim without the call, or an engine below ``forkAPI``.
    typealias Call = (_ browser: Int32, _ enabled: Bool) -> Bool

    /// `cmux_shim_draw_on_input_key_frames(browser)`: frames this mode drew for a key on that page, or -1
    /// when the engine has no such call. Nil without a shim or below ``forkAPI``.
    typealias KeyFrames = (_ browser: Int32) -> Int32

    private let call: Call?
    private let keyFramesCall: KeyFrames?
    private let isOn: () -> Bool
    /// Browsers whose agent chat page the fork draws keys for.
    private(set) var drawing: Set<Int32> = []
    /// The last address of each browser seen here, to apply a setting change to the open pages.
    private var addresses: [Int32: URL] = [:]
    private var settingLoop: ObservationLoop?

    init(call: Call?, keyFrames: KeyFrames? = nil,
         isOn: @escaping () -> Bool = { CEFDrawOnInput.setting.value }) {
        self.call = call
        self.keyFramesCall = keyFrames
        self.isOn = isOn
    }

    convenience init(shim: CEFShimLibrary?, apiVersion: Int32) {
        let call: Call? = apiVersion >= Self.forkAPI
            ? shim?.browserSetDrawOnInput.map { fn in { browser, enabled in fn(browser, enabled ? 1 : 0) == 1 } } : nil
        let keyFrames: KeyFrames? = apiVersion >= Self.forkAPI
            ? shim?.drawOnInputKeyFrames.map { fn in { browser in fn(browser) } } : nil
        self.init(call: call, keyFrames: keyFrames)
        // A Debug Settings change reaches the open chats (the tunable's read is observable per key).
        if call != nil { settingLoop = ObservationLoop { [weak self] in self?.settingChanged() } }
    }

    /// An agent chat page: cmux's first-party agent page (`cmux-page://cmux.agent/...`).
    nonisolated static func isAgentChat(_ url: URL?) -> Bool {
        url?.scheme == "cmux-page" && url?.host == "cmux.agent"
    }

    /// A browser's address changed (or it was attached with one): opts it in or out.
    func addressChanged(browser: Int32, url: URL?) {
        guard call != nil else { return }
        addresses[browser] = url
        apply(browser, wants: isOn() && Self.isAgentChat(url))
    }

    /// The setting changed: every open page follows it.
    func settingChanged() {
        guard call != nil else { return }
        let on = isOn()
        for (browser, url) in addresses { apply(browser, wants: on && Self.isAgentChat(url)) }
    }

    /// A browser closed; the fork drops its watch with the page.
    func closed(browser: Int32) {
        addresses[browser] = nil
        drawing.remove(browser)
    }

    /// Whether this engine answers the per-key frame count (fork API ``forkAPI`` and a shim with the call).
    var hasKeyFrames: Bool { keyFramesCall != nil }

    /// Frames this mode drew for keys, per page it is on (`debug.cef.draw_on_input`): a bench tells a live mode
    /// from an inert one by this growing, since an engine below ``forkAPI`` takes no call and nothing changes.
    /// Empty when the engine has no counter, so a reader never mistakes a missing call for zero frames.
    var keyFrames: [Int32: Int32] {
        guard let keyFramesCall else { return [:] }
        var frames: [Int32: Int32] = [:]
        for browser in drawing {
            let count = keyFramesCall(browser)
            if count >= 0 { frames[browser] = count }
        }
        return frames
    }

    private func apply(_ browser: Int32, wants: Bool) {
        guard let call, wants != drawing.contains(browser) else { return }
        guard call(browser, wants) else { return }
        if wants { drawing.insert(browser) } else { drawing.remove(browser) }
    }
}
