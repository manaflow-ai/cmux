import CmuxNextPages
import CmuxNextSettings
import Foundation

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
public protocol AgentSourceUsesPageContext: AnyObject {
    func matches(_ file: URL) -> Bool
    func read(cursor: String?) async throws -> JSONValue
    func reveal(reply: String, turn: String) -> Bool
}

public enum AgentSourceUsesPageBridge {
    @MainActor public static func sourceUses(
        local: Bool, file: URL?, requested: URL, matches: Bool, source: (any AgentSourceUsesPageContext)?,
        read: @escaping () -> Bool, stillCurrent: @escaping () -> Bool, cursor: String?
    ) async throws -> JSONValue {
        guard local, matches, let file, let source, source.matches(file) else {
            throw PageError.invalidParams("no source context for this page's file")
        }
        let result = try await source.read(cursor: cursor)
        guard read(), stillCurrent() else { throw PageError.closed }
        _ = requested
        return result
    }

    @MainActor public static func reveal(
        gesture: Bool, local: Bool, file: URL?, requested: URL, matches: Bool, source: (any AgentSourceUsesPageContext)?,
        reply: String?, turn: String?
    ) throws -> JSONValue {
        guard gesture else { throw PageError(code: "cmux.page.gesture", message: "opening a reply needs a user gesture") }
        guard local, matches, let file, let source, source.matches(file), let reply, let turn else {
            throw PageError.invalidParams("reply is not a recorded use of this page's file")
        }
        guard source.reveal(reply: reply, turn: turn) else {
            throw PageError.invalidParams("reply is not a recorded use of this page's file")
        }
        _ = requested
        return .object([:])
    }
}

extension FilePageSourceContext: AgentSourceUsesPageContext {}

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
