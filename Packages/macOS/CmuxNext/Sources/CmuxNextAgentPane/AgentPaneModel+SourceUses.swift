import CmuxNextPages
public import CmuxNextSettings
public import Foundation

extension AgentPaneModel {
    /// A local document's reverse links use only the chat that opened it. Remote carriers
    /// need their own authenticated bridge; a socket on this Mac is never their fallback.
    public var canReadSourceUses: Bool {
        !chatIsElsewhere && hasHandshake && sessionId != nil && (transport.acpmuxSocket ?? transport.socketPath) != nil
    }

    public func sourceUses(uri: String, session: String, cursor: String?) async throws -> JSONValue {
        guard canReadSourceUses, sessionId == session, let socket = transport.acpmuxSocket ?? transport.socketPath else {
            throw PageError.closed
        }
        var params: [String: any Sendable] = ["sessionId": session, "uri": uri, "limit": 20]
        if let cursor { params["cursor"] = cursor }
        let result = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/source_uses", params: params,
                                                     deadline: .seconds(10))
        guard canReadSourceUses, sessionId == session,
              (transport.acpmuxSocket ?? transport.socketPath) == socket,
              let json = JSONValue(foundation: result), json["sessionId"]?.stringValue == session,
              json["uri"]?.stringValue == uri else { throw PageError.closed }
        return json
    }
}

/// File-page reverse links consume only a context created by the originating agent pane.
@MainActor
public enum AgentSourceUsesPageBridge {
    public static func config(local: Bool, file: URL, source: FilePageSourceContext?) -> [String: JSONValue] {
        guard local, let source, source.matches(file) else { return [:] }
        return ["sourceUses": true, "sourceContext": .string(source.id)]
    }

    public static func call(op: String, params: JSONValue, gesture: Bool, markdown: Bool,
                            local: Bool, file: URL?, canonical: (URL) -> URL,
                            source: FilePageSourceContext?, isCurrent: () -> Bool) async throws -> JSONValue? {
        let namespace = PageDescriptor.markdown.id
        let reading = op == "\(namespace).sourceUses"
        guard markdown, reading || op == "\(namespace).revealSourceUse" else { return nil }
        if !reading, !gesture {
            throw PageError(code: "cmux.page.gesture", message: "opening a reply needs a user gesture")
        }
        let requested = try FilePageRequest.path(params["path"])
        guard local, let file, canonical(requested) == file, let source, source.matches(file) else {
            throw PageError.invalidParams("no source context for this page's file")
        }
        if reading {
            let result = try await source.read(cursor: params["cursor"]?.stringValue)
            guard isCurrent() else { throw PageError.closed }
            return result
        }
        guard let reply = params["replyId"]?.stringValue, let turn = params["turnId"]?.stringValue,
              source.reveal(reply: reply, turn: turn) else {
            throw PageError.invalidParams("reply is not a recorded use of this page's file")
        }
        return .object([:])
    }
}

extension AgentPaneModel {
    /// Installs the checked file callbacks while keeping source provenance in the pane target.
    public func installSourceFileOpener(
        noteOpened: @escaping (URL) -> Void,
        openTab: @escaping (URL, FilePageSourceContext?) -> Bool,
        openOther: @escaping (URL, AgentPaneFileTarget) -> Bool,
        reveal: @escaping (String, Int) -> Bool
    ) {
        onOpenFile = { url, target in
            noteOpened(url)
            return target == .tab ? openTab(url, nil) : openOther(url, target)
        }
        onOpenFileWithSource = { [weak self] url, target, rawPath in
            guard let self else { return false }
            noteOpened(url)
            guard target == .tab else { return openOther(url, target) }
            guard let session = self.sessionId, self.canReadSourceUses,
                  let rawPath, let uri = FilePageSourceContext.sourceURI(rawPath) else {
                return openTab(url, nil)
            }
            let context = FilePageSourceContext(file: url,
                read: { [weak self] cursor in
                    guard let self else { throw PageError.closed }
                    return try await self.sourceUses(uri: uri, session: session, cursor: cursor)
                },
                current: { [weak self] in
                    self?.sessionId == session && self?.canReadSourceUses == true
                },
                reveal: { [weak self] reply, seq in
                    guard let self, self.sessionId == session, self.canReadSourceUses else { return false }
                    return reveal(reply, seq)
                })
            return openTab(url, context)
        }
    }
}
