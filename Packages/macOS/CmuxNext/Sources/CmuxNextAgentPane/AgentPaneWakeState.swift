public import Foundation
import WebKit

/// What a chat page holds that acpmux does not (#20162 follow-up): the composer's attachments,
/// shell mode with its unrun command, and where the transcript rests. A hidden chat whose page
/// lets go keeps it with its tab, and the page built when it shows again gets it back with its
/// handshake (`wake`), so it comes back as it was left. The draft's text is acpmux's.
public nonisolated struct AgentPaneWakeState: Codable, Sendable, Equatable {
    /// The composer's chips (`attachments.ts` `ComposerAttachment`), images and files with their contents.
    public var attachments: [Attachment]?
    /// The composer was in shell mode.
    public var shell: Bool?
    /// Shell mode's command, typed and not run.
    public var shellText: String?
    /// Where the transcript rested, when the reader was scrolled up.
    public var scrollAnchor: AgentPaneScrollAnchor?
    /// The transcript rested at its latest message. With neither this nor ``scrollAnchor`` its
    /// place is unknown (never shown, or a subagent's view was open): the kept anchor stands.
    public var atLatest: Bool?
    /// The page holds or sends prompts waiting for a folder trust answer (webviews trustHeld.ts),
    /// each with its send's gesture ticket, which ends with the page: it is not let go.
    public var holdsPrompts: Bool?
    /// The page holds edits, attachments or sends that its wake state cannot restore, or has an
    /// input method or popup open. Only a hidden-page release asks to retain that state.
    public var holdsPageState: Bool?
    /// The subagents' unsent prompts this page kept (webviews subagents/subagentDrafts.ts), by draft
    /// key: a subagent has no acpmux session to keep it, so the page's wake state does. A quit keeps
    /// each one's text in a file of its own (``AgentPaneRelaunchWake``), so it has no size limit.
    public var subagentDrafts: [String: SubagentDraft]?

    /// A subagent's unsent prompt as text, its pasted chips in their places, with when it was kept
    /// (ms since 1970), which decides between two pages' copies. An empty text is a cleared draft.
    public nonisolated struct SubagentDraft: Codable, Sendable, Equatable {
        public var text: String?
        public var at: Double

        public init(text: String?, at: Double) {
            (self.text, self.at) = (text, at)
        }
    }

    public nonisolated struct Attachment: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String
        public var name: String
        public var mimeType: String
        public var size: Double
        public var data: String?
        public var text: String?
        public var pageCount: Int?
        /// A link chip's file or folder on this computer (Attach files or folders).
        public var path: String?
        /// A normalized image preview's original file on the session machine.
        public var originalPath: String?
        public var originalName: String?
        /// The app the chip came from (``AttachmentSource``), kept with the chip so a reopened chat's
        /// chip wears its icon again.
        public var source: AttachmentSource?

        public init(id: String, kind: String, name: String, mimeType: String, size: Double,
                    data: String? = nil, text: String? = nil, pageCount: Int? = nil, path: String? = nil,
                    originalPath: String? = nil, originalName: String? = nil, source: AttachmentSource? = nil) {
            (self.id, self.kind, self.name, self.mimeType, self.size) = (id, kind, name, mimeType, size)
            (self.data, self.text, self.pageCount, self.path) = (data, text, pageCount, path)
            (self.originalPath, self.originalName, self.source) = (originalPath, originalName, source)
        }
    }

    public init(attachments: [Attachment]? = nil, shell: Bool? = nil, shellText: String? = nil,
                scrollAnchor: AgentPaneScrollAnchor? = nil, atLatest: Bool? = nil, holdsPrompts: Bool? = nil,
                holdsPageState: Bool? = nil, subagentDrafts: [String: SubagentDraft]? = nil) {
        self.attachments = attachments
        self.shell = shell
        self.shellText = shellText
        self.scrollAnchor = scrollAnchor
        self.atLatest = atLatest
        self.holdsPrompts = holdsPrompts
        self.holdsPageState = holdsPageState
        self.subagentDrafts = subagentDrafts
    }

    /// Nothing to hand back.
    public var isEmpty: Bool {
        (attachments ?? []).isEmpty && shell != true && scrollAnchor == nil && atLatest != true
            && holdsPrompts != true && holdsPageState != true && (subagentDrafts ?? [:]).isEmpty
    }

    /// The page's `pane.wakeState` answer; empty when the page has no such action (an older page)
    /// or the answer is malformed.
    init(page value: Any?) {
        guard let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let state = try? JSONDecoder().decode(Self.self, from: data) else {
            self.init()
            return
        }
        self = state
    }
}

extension AgentPaneView {
    /// Asks the page what it holds that acpmux does not, before it lets go. Nil when it does not
    /// answer within `limit`; empty when it holds nothing.
    public func wakeState(limit: Duration = .seconds(1)) async -> AgentPaneWakeState? {
        await AgentPaneWakeState.read(self, limit: limit, ask: "{}")
    }

    /// A retired page: prompts it holds for a folder trust answer live only in it, so it puts them
    /// into their chats' drafts before its bridge goes (webviews trustHeld.ts); then `close` runs.
    public func releaseHeldPrompts(then close: @escaping @MainActor (AgentPaneView) -> Void) {
        // task-owner: one release then close per retired page; ends with its close
        Task { @MainActor in
            await AgentPaneWakeState.releaseHeldPrompts(in: self)
            close(self)
        }
    }
}

extension AgentPaneWakeState {
    /// `view`'s wake state as the app quits: the page puts prompts it holds for a folder trust
    /// answer into its drafts (webviews trustHeld.ts) instead of asking to stay.
    @MainActor public static func quitting(_ view: AgentPaneView, limit: Duration) async -> AgentPaneWakeState? {
        await read(view, limit: limit, ask: "{quitting: true}")
    }

    /// The tab closes: the page puts prompts it holds for a folder trust answer into their chats'
    /// drafts while its bridge still answers. Done when it answered or `limit` passed. The page
    /// writes them within `draftSettleMs` of schemas/agent-pane/wake-state.json, so this waits as
    /// long as a quit's ask (``AgentPaneRelaunchWake/askLimit``), which outlasts it.
    @MainActor public static func releaseHeldPrompts(
        in view: AgentPaneView,
        limit: Duration = AgentPaneRelaunchWake.askLimit
    ) async {
        _ = await read(view, limit: limit, ask: "{closing: true}")
    }

    /// Why a hidden page asked for its wake state (`wake`, nil when it did not answer in time) stays
    /// instead of being let go, for the log; nil when it may go. A kept page is asked again after
    /// the planner's `keptRecheck`.
    public static func keepReason(_ wake: AgentPaneWakeState?, hasHandshake: Bool) -> String? {
        // A connected page that did not say what it holds (a large attachment still encoding)
        // stays: letting it go would drop its chips.
        if wake == nil, hasHandshake { return "no wake state in time" }
        // A page holding prompts for a folder trust answer stays: each keeps its send's gesture
        // ticket, which ends with the page (webviews trustHeld.ts). Asked again, it goes once its
        // prompts have.
        if wake?.holdsPrompts == true { return "holds prompts for a trust answer" }
        if wake?.holdsPageState == true { return "holds page state" }
        return nil
    }

    @MainActor static func read(_ view: AgentPaneView, limit: Duration, ask: String) async -> AgentPaneWakeState? {
        await agentPaneFirst(within: limit) { [weak view] in
            guard let view else { return nil }
            let script = "const read = window.cmuxAcpmuxActions?.['pane.wakeState']; return read ? await read(\(ask)) : null;"
            let value = try? await view.callPageScript(script)
            return AgentPaneWakeState(page: value)
        }
    }
}
