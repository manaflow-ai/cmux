public import CoreGraphics
public import Foundation

/// Design mode on a tab (plans/cmux-next/design-mode-DESIGN.md): classic's runtime in cmux's
/// isolated world, its messages arriving as `.designMode` intents.
extension BrowserTab {
    /// Turns design mode on: readies the engine's message path, then installs and enables the
    /// runtime. The page draws its own hover outline and badges from here on.
    /// - Throws: ``BrowserTabError`` when the tab is closed or the page refused the script.
    public func enableDesignMode(_ script: BrowserDesignModeScript = BrowserDesignModeScript()) async throws {
        let chromium = self is CEFTab
        if let tab = self as? CEFTab { try await tab.agentRelay.prepareDesignMode() }
        _ = try await evaluate(try script.enableScript(chromium: chromium), world: .isolated, gesture: .cmux)
    }

    /// Turns design mode off and puts back every edit it made; harmless when it is off.
    public func disableDesignMode() async {
        _ = try? await evaluate(BrowserDesignModeScript.disableScript, world: .isolated, gesture: .cmux)
    }

    /// The page as shown, without design mode's own outlines, pins and bubble; nil when the tab
    /// cannot draw. ``BrowserDesignModeCard/crop(from:)`` cuts each pick from it.
    public func designModeSnapshot() async -> CGImage? {
        _ = try? await evaluate("globalThis.__cmuxDesignMode?.prepareCapture(); true", world: .isolated, gesture: .cmux)
        let image = try? await snapshot()
        _ = try? await evaluate("globalThis.__cmuxDesignMode?.finishCapture(); true", world: .isolated, gesture: .cmux)
        return image
    }

    /// Answers the page's request to capture a drawn region (`message`, a design mode message):
    /// the stroke's own bounds complete it, since cmux crops regions from its own capture.
    /// - Returns: false when `message` is not a capture request, so the caller handles it.
    @discardableResult
    public func completeDesignModeCapture(_ message: Data) -> Bool {
        guard let completion = BrowserDesignModeCards.captureCompletion(message) else { return false }
        Task { [weak self] in _ = try? await self?.evaluate(completion, world: .isolated, gesture: .cmux) }
        return true
    }

    /// Takes the pick at `selector` off the page (its outline and pin) and renumbers the rest:
    /// a chat let go of its card.
    public func removeDesignModePick(_ selector: String) async {
        _ = try? await evaluate("globalThis.__cmuxDesignMode?.removeSelection(\(jsString(selector))); true",
                                world: .isolated, gesture: .cmux)
    }

    /// Offers Command-Return (send the pick to the agent as a comment thread) in the comment bubble,
    /// or takes it away: the workspace's agent chat keeps comment threads (`diff-comments-threads-v1`) or not.
    public func setDesignModeSendAvailable(_ available: Bool) async {
        _ = try? await evaluate("globalThis.__cmuxDesignMode?.setSendAvailable(\(available)); true", world: .isolated, gesture: .cmux)
    }

    /// Shows the comment thread of the pick at `selector` on the page, next to its pin: `state`
    /// (`sending`, `sent`, `answered` or `failed`) and the agent's `reply`; a nil `state` takes the
    /// thread card away.
    public func setDesignModeThread(_ selector: String, state: String?, reply: String?) async {
        let value: [String: Any] = state.map { ["state": $0, "reply": reply ?? ""] } ?? [:]
        // main-actor-ok: one thread's state and one agent reply, bounded by the runtime.
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        let json = state == nil ? "null" : String(decoding: data, as: UTF8.self)
        _ = try? await evaluate("globalThis.__cmuxDesignMode?.setThread(\(jsString(selector)), \(json)); true",
                                world: .isolated, gesture: .cmux)
    }

    /// Puts a kept comment thread back on the page (design mode turned on again, the page reloaded):
    /// the element at `selector` becomes an added pick with `comment`, its thread card showing
    /// `state` and `reply`, and the page reports it as it reports any pick.
    /// - Returns: False when no element has that selector now, or design mode is off.
    public func restoreDesignModeThread(_ selector: String, comment: String, state: String, reply: String?) async -> Bool {
        let value: [String: Any] = ["state": state, "reply": reply ?? ""]
        // main-actor-ok: one thread's state and one agent reply, bounded by the runtime.
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        let script = "globalThis.__cmuxDesignMode?.restoreThread(\(jsString(selector)), \(jsString(comment)), "
            + String(decoding: data, as: UTF8.self) + ") === true"
        return (try? await evaluate(script, world: .isolated, gesture: .cmux)) == .bool(true)
    }

    /// Drives the open comment bubble through the runtime's own path (captures and tours): types
    /// `draft` into it when given, then adds the pick when `commit` is true.
    /// - Returns: False when the tab is closed, the page refused the script, or design mode is off.
    public func driveDesignMode(draft: String?, commit: Bool) async -> Bool {
        let calls = (draft.map { ["api.draft(\(jsString($0)));"] } ?? []) + (commit ? ["api.commit();"] : [])
        let script = "(() => { const api = globalThis.__cmuxDesignMode; if (!api) return false; "
            + calls.joined() + " return true; })()"
        return (try? await evaluate(script, world: .isolated, gesture: .cmux)) == .bool(true)
    }
}

/// `text` as a JavaScript string literal (JSON's quoting, which JavaScript reads the same way).
private func jsString(_ text: String) -> String {
    // main-actor-ok: one design-mode comment draft the person typed into the bubble, a line or two.
    let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
    return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
}
