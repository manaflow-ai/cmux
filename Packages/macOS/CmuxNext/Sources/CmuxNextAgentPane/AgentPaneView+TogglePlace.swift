import Foundation

/// Toggle Terminal and Chat's place on the chat face: a swap lands at the same turn in the other
/// view, both ways (Leo, 2026-11-12: two live views of one session, instant both ways). The page
/// names its prompts and the turn in view, and places a turn before the pane shows
/// (`conversation/togglePlace.ts`, VirtualTranscript `placeNow`); the match against the terminal is
/// Rust's (cmux-window-rules `tabs::place`, `TerminalChatPlacing`).
extension AgentPaneView {
    /// The longest a swap waits on the page: past it the view shows where it is.
    public static let togglePlaceTimeout: Duration = .milliseconds(60)

    /// Whether the chat follows its latest message: the place its tab keeps is none
    /// (``AgentPaneScrollAnchors``). One lookup, no page call: a swap at the latest message waits on nothing.
    public var togglePlaceAtLatest: Bool {
        guard let session = model.sessionId, let anchors = AgentPaneScrollAnchors.shared else { return true }
        return anchors.anchor(for: session, tab: model.tabKey()) == nil
    }

    /// The chat's prompts, oldest first, and the one whose turn is in view (nil at the latest
    /// message); nil when the page does not answer in time.
    public func togglePlacePrompts() async -> (prompts: [String], at: Int?)? {
        let read: TogglePlaceRead? = await Self.within(Self.togglePlaceTimeout) { [weak self] in
            let body = "return window.cmuxAcpmuxBridge?.togglePlace?.() ?? null;"
            guard let reply = try? await self?.callPageScript(body) as? [String: Any],
                  let prompts = reply["prompts"] as? [String] else { return nil }
            return TogglePlaceRead(prompts: prompts, at: (reply["at"] as? NSNumber)?.intValue)
        }
        return read.map { ($0.prompts, $0.at) }
    }

    /// Places prompt `index`'s turn at the top of the view, or the latest message for nil, before
    /// the pane shows. False when the page does not have it or does not answer in time.
    @discardableResult
    public func togglePlaceShow(prompt index: Int?) async -> Bool {
        await Self.within(Self.togglePlaceTimeout) { [weak self] in
            let body = "return window.cmuxAcpmuxBridge?.placeToggle?.(at) ?? false;"
            let at: Any = index.map { NSNumber(value: $0) } ?? NSNull()
            return (try? await self?.callPageScript(body, arguments: ["at": at])) as? Bool
        } ?? false
    }

    private struct TogglePlaceRead: Sendable {
        var prompts: [String]
        var at: Int?
    }

    /// `work`'s answer, or nil once `timeout` passes first: a page script cannot be cancelled
    /// (WebKit's ignores a timeout), so the swap stops waiting on it instead.
    private static func within<T: Sendable>(_ timeout: Duration, _ work: @escaping @MainActor () async -> T?) async -> T? {
        let answer = TogglePlaceAnswer<T>()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            // task-owner: one bounded page read; the answer below ends the wait whichever comes first
            Task { @MainActor in answer.finish(await work()) }
            // task-owner: the wait's deadline, which ends it if the page has not answered
            Task { @MainActor in
                // wakeup-allow: one-shot deadline of a swap (60 ms), never a poll
                try? await Task.sleep(for: timeout)
                answer.finish(nil)
            }
        }
    }
}

/// The first of a page's answer and its deadline (``AgentPaneView/within(_:_:)``).
@MainActor
private final class TogglePlaceAnswer<T: Sendable> {
    var continuation: CheckedContinuation<T?, Never>?

    func finish(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
