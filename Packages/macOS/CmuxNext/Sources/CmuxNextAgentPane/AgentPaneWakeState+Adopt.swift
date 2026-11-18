import CmuxNextSettings
import Foundation

/// A chat selected again after its hidden page let go takes the pool's connected page, and what the last page
/// held goes to that page with its adopt event (decision 2026-11-16;
/// ``AgentPaneView/adoptSession(_:tab:revealTurn:wake:moved:)``), in the shape of the handshake's `wake`. Before,
/// only a new page's handshake could hand the state back, so the return loaded, connected and attached cold.
///
/// The model of the page that took the chat keeps the state (``AgentPaneModel/pendingWake``) until the page says
/// that it applied it (`pane.painted {appliedWake: true}`). A page that dies before that loads again, and its
/// handshake hands the state, as a cold page's does.
nonisolated extension AgentPaneWakeState {
    /// The most content, in UTF-8 bytes, of a state that an adopt event carries. No measure set it: the event is
    /// a script that the host builds and the page parses on the click's path, and 1 MB keeps a few screenshots
    /// (a chip holds its file as base64 text) while it bounds that work. A state over it gets a page of its own,
    /// whose handshake hands it over off that path.
    public static let adoptEventLimit = 1_000_000

    /// The content this state holds, in UTF-8 bytes: each chip's file content and text, shell mode's command and
    /// the subagents' unsent prompts. The rest (ids, names, the place, the folds) is short, and the page bounds
    /// the folds. One count for each chip and draft.
    public var contentBytes: Int {
        var bytes = shellText?.utf8.count ?? 0
        for chip in attachments ?? [] {
            bytes += (chip.data?.utf8.count ?? 0) + (chip.text?.utf8.count ?? 0)
        }
        for draft in (subagentDrafts ?? [:]).values {
            bytes += draft.text?.utf8.count ?? 0
        }
        return bytes
    }

    /// Whether an adopt event carries this state (``adoptEventLimit``).
    public var fitsAdoptEvent: Bool { contentBytes <= Self.adoptEventLimit }

    /// Where the transcript rested when the page let go, for the adopt event's place: a place, `.some(nil)` at
    /// its latest message, nil when the page did not know (never shown, or a subagent's view was open), so the
    /// kept place stands. The released page's place is newer than the kept one: a scroll that settled while the
    /// page was hidden was never reported.
    var adoptedPlace: AgentPaneScrollAnchor?? {
        if let scrollAnchor { return .some(scrollAnchor) }
        if atLatest == true { return .some(nil) }
        return nil
    }

    /// The adopt event's place: the one that `wake` holds, else `kept` (the tab's kept place, or nil with no store).
    static func adoptPlace(of wake: AgentPaneWakeState?, kept: AgentPaneScrollAnchor??) -> AgentPaneScrollAnchor?? {
        if let wake, let place = wake.adoptedPlace { return .some(place) }
        return kept
    }

    /// This state as the adopt event carries it: the JSON that the handshake's `wake` has. Nil when it does not
    /// encode, which no state does. Linear in the state's size, which ``adoptEventLimit`` bounds.
    var adoptEventValue: JSONValue? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONValue.parse(data)
    }
}
