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
    /// Where the transcript rested; nil at its latest message.
    public var scrollAnchor: AgentPaneScrollAnchor?

    public nonisolated struct Attachment: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String
        public var name: String
        public var mimeType: String
        public var size: Double
        public var data: String?
        public var text: String?
        public var pageCount: Int?

        public init(id: String, kind: String, name: String, mimeType: String, size: Double,
                    data: String? = nil, text: String? = nil, pageCount: Int? = nil) {
            (self.id, self.kind, self.name, self.mimeType, self.size) = (id, kind, name, mimeType, size)
            (self.data, self.text, self.pageCount) = (data, text, pageCount)
        }
    }

    public init(attachments: [Attachment]? = nil, shell: Bool? = nil, shellText: String? = nil,
                scrollAnchor: AgentPaneScrollAnchor? = nil) {
        self.attachments = attachments
        self.shell = shell
        self.shellText = shellText
        self.scrollAnchor = scrollAnchor
    }

    /// Nothing a fresh page would not show by itself.
    public var isEmpty: Bool {
        (attachments ?? []).isEmpty && shell != true && (shellText ?? "").isEmpty && scrollAnchor == nil
    }

    /// The page's `pane.wakeState` answer; nil when it has nothing to keep or is malformed.
    init?(page value: Any?) {
        guard let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let state = try? JSONDecoder().decode(Self.self, from: data), !state.isEmpty else { return nil }
        self = state
    }
}

extension AgentPaneView {
    /// Asks the page what it holds that acpmux does not, before it lets go. Nil when it has
    /// nothing, has not connected, or does not answer within `limit`.
    public func wakeState(limit: Duration = .seconds(1)) async -> AgentPaneWakeState? {
        await agentPaneFirst(within: limit) { [weak self] in
            guard let webView = self?.webView else { return nil }
            let script = "const read = window.cmuxAcpmuxActions?.['pane.wakeState']; return read ? await read({}) : null;"
            let value = try? await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
            return AgentPaneWakeState(page: value)
        }
    }
}
