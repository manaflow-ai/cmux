import Foundation

/// Toggle Terminal and Chat's place on the chat face: a swap lands at the same turn in the other
/// view, both ways (Leo, 2026-11-12: two live views of one session, instant both ways). The page
/// names its prompts and the turn in view, and places a turn before the pane shows
/// (`conversation/togglePlace.ts`, VirtualTranscript `placeNow`); the match against the terminal is
/// Rust's (cmux-window-rules `tabs::place`, `TerminalChatPlacing`). Each call takes the swap's one
/// deadline: past it the swap shows the chat where it is.
extension AgentPaneView {
    /// What the page's placement leaves for its answer to arrive before the swap's deadline: a
    /// placement after the chat shows would be a jump, so the page skips one that late.
    static let togglePlaceReplyMargin: Duration = .milliseconds(10)

    /// Whether the chat follows its latest message: the place its tab keeps is none
    /// (``AgentPaneScrollAnchors``; the page reports a change of following at once). One lookup,
    /// no page call: a swap at the latest message waits on nothing.
    public var togglePlaceAtLatest: Bool {
        guard let session = model.sessionId, let anchors = AgentPaneScrollAnchors.shared else { return true }
        return anchors.anchor(for: session, tab: model.tabKey()) == nil
    }

    /// The chat's prompts, oldest first, and the one whose turn is in view (nil at the latest
    /// message); nil when the page does not answer by `deadline`.
    public func togglePlacePrompts(by deadline: ContinuousClock.Instant) async -> (prompts: [String], at: Int?)? {
        let read: TogglePlaceRead? = await Self.answer(by: deadline) { [weak self] in
            let body = "return window.cmuxAcpmuxBridge?.togglePlace?.() ?? null;"
            guard let reply = try? await self?.callPageScript(body) as? [String: Any],
                  let prompts = reply["prompts"] as? [String] else { return nil }
            return TogglePlaceRead(prompts: prompts, at: (reply["at"] as? NSNumber)?.intValue)
        }
        return read.map { ($0.prompts, $0.at) }
    }

    /// Places prompt `index`'s turn at the top of the view, or the latest message for nil, before
    /// the pane shows. False when the page does not have it or does not answer by `deadline`; the
    /// page skips a placement it gets too late to answer by then.
    @discardableResult
    public func togglePlaceShow(prompt index: Int?, by deadline: ContinuousClock.Instant) async -> Bool {
        let left = ContinuousClock.now.duration(to: deadline) - Self.togglePlaceReplyMargin
        guard left > .zero else { return false }
        let until = (Date().timeIntervalSince1970 + Self.seconds(left)) * 1000
        return await Self.answer(by: deadline) { [weak self] in
            let body = "return window.cmuxAcpmuxBridge?.placeToggle?.(at, until) ?? false;"
            let at: Any = index.map { NSNumber(value: $0) } ?? NSNull()
            return (try? await self?.callPageScript(body, arguments: ["at": at, "until": until])) as? Bool
        } ?? false
    }

    private struct TogglePlaceRead: Sendable {
        var prompts: [String]
        var at: Int?
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// `work`'s answer, or nil once `deadline` passes first: a page script cannot be cancelled
    /// (WebKit's ignores a timeout), so the swap stops waiting on it instead.
    static func answer<T: Sendable>(by deadline: ContinuousClock.Instant,
                                            _ work: @escaping @MainActor () async -> T?) async -> T? {
        guard ContinuousClock.now < deadline else { return nil }
        let answer = TogglePlaceAnswer<T>()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            // task-owner: one bounded page read; the answer below ends the wait whichever comes first
            Task { @MainActor in answer.finish(await work()) }
            // task-owner: the swap's deadline, which ends the wait if the page has not answered
            Task { @MainActor in
                // wakeup-allow: one-shot deadline of a swap (60 ms in all), never a poll
                try? await Task.sleep(until: deadline, clock: .continuous)
                answer.finish(nil)
            }
        }
    }
}

/// The first of a page's answer and its deadline (``AgentPaneView/answer(by:_:)``).
@MainActor
private final class TogglePlaceAnswer<T: Sendable> {
    var continuation: CheckedContinuation<T?, Never>?

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    func finish(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
