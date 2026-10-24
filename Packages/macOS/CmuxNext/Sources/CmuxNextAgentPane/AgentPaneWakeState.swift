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
    /// The files still holding the contents of ``attachments`` that carry none yet: a relaunched
    /// chat's chips, read back when its page asks (``readingBack(budget:)``). Never sent to the page.
    public var kept: AgentPaneKeptChips?

    /// What the page sends and receives: everything but ``kept``.
    private enum CodingKeys: String, CodingKey {
        case attachments, shell, shellText, scrollAnchor, atLatest
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

        public init(id: String, kind: String, name: String, mimeType: String, size: Double,
                    data: String? = nil, text: String? = nil, pageCount: Int? = nil, path: String? = nil,
                    originalPath: String? = nil, originalName: String? = nil) {
            (self.id, self.kind, self.name, self.mimeType, self.size) = (id, kind, name, mimeType, size)
            (self.data, self.text, self.pageCount, self.path) = (data, text, pageCount, path)
            (self.originalPath, self.originalName) = (originalPath, originalName)
        }
    }

    public init(attachments: [Attachment]? = nil, shell: Bool? = nil, shellText: String? = nil,
                scrollAnchor: AgentPaneScrollAnchor? = nil, atLatest: Bool? = nil) {
        self.attachments = attachments
        self.shell = shell
        self.shellText = shellText
        self.scrollAnchor = scrollAnchor
        self.atLatest = atLatest
    }

    /// Nothing to hand back.
    public var isEmpty: Bool {
        (attachments ?? []).isEmpty && shell != true && scrollAnchor == nil && atLatest != true
    }

    /// This state with the contents of its ``kept`` chips read back from their files, off the main
    /// actor, within `budget` bytes (a chip whose file is gone or past the budget is left out); itself
    /// when it keeps none.
    /// - Parameter budget: The most bytes read back for this state's chips.
    public func readingBack(budget: Int = AgentPaneRelaunchWake.defaultMaximumAttachmentBytes) async -> AgentPaneWakeState {
        guard kept != nil else { return self }
        let state = self
        return await Task.detached { state.readBackNow(budget: budget) }.value
    }

    /// ``readingBack(budget:)`` on the calling thread (the quit's save, already off the main actor).
    func readBackNow(budget: Int) -> AgentPaneWakeState {
        guard let kept else { return self }
        var state = self
        var budget = budget
        state.kept = nil
        state.attachments = attachments.map { AgentPaneAttachmentFiles.readBack($0, files: kept.files, in: kept.folder, budget: &budget) }
        return state
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
        await agentPaneFirst(within: limit) { [weak self] in
            guard let self else { return nil }
            let script = "const read = window.cmuxAcpmuxActions?.['pane.wakeState']; return read ? await read({}) : null;"
            let value = try? await self.callPageScript(script)
            return AgentPaneWakeState(page: value)
        }
    }
}
