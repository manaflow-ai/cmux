public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// A tab that shows only a chat's own patch (``DiffChatPatch``, ``DiffPageProvider/chatPatch``): the
/// turn's changes the chat built from its tool calls, for a folder in no repository or a turn that
/// wrote a file outside it. The page asks the same `cmux.diff.*` ops; this answers them without the
/// sidecar: the handshake, a Last turn session whose patch is the chat's (written to the grant's turn
/// patch file the page then fetches), its close, an empty branch list, and the shared prefs and
/// viewed marks. Nothing else: no git, stage, revert, whole files or file opens, since the patch may
/// name files that are on another machine or nowhere.
extension DiffPageProvider {
    static let chatPatchMethods: Set<String> = ["protocolHandshake", "sessionOpen", "sessionClose", "branchList"]

    func chatPatchCall(_ op: String, params: JSONValue) async throws -> JSONValue {
        if let value = try await storeCall(op, params: params) { return value }
        let method = String(op.dropFirst("cmux.diff.".count))
        guard op.hasPrefix("cmux.diff."), Self.chatPatchMethods.contains(method) else { throw PageError.unknownOp(op) }
        guard let ready else { throw PageError(code: "sidecarUnavailable", message: "No diff is open") }
        let tab: DiffTabReady
        do {
            tab = try await ready.value
        } catch let failure as DiffTabFailure {
            throw PageError(code: "sidecarUnavailable", message: failure.message)
        }
        switch method {
        case "protocolHandshake":
            return ["type": "handshake", "value": ["protocolVersion": 1, "capabilities": .array([])]]
        case "sessionOpen":
            guard let patch = tab.chatPatch, DiffTurnPatch.opens(params.objectValue ?? [:]) else {
                throw PageError(code: "notAllowed", message: "This diff tab shows only the chat's changes")
            }
            try await Self.writeTurnPatch(patch.text, to: tab.grant)
            let id = UUID().uuidString.lowercased()
            sessions.insert(id)
            return Self.sessionOpened(sessionID: id, source: DiffTurnPatch.pageSource, requestPath: DiffTurnPatch.requestPath,
                                      token: tab.grant.token, byteLength: patch.text.utf8.count)
        case "sessionClose":
            if let id = params["sessionId"]?.stringValue { sessions.remove(id) }
            return ["type": "sessionClosed"]
        default:
            return ["type": "branches", "value": ["groups": .array([])]]
        }
    }

    /// A chat patch tab shows `patch` (a chat's newer one) from `runtime`: the old grant, its sessions
    /// and files are retired, then `reload` loads the page again. One at a time, the newest last, so
    /// two never retire the same grant.
    public func show(_ patch: DiffChatPatch, from runtime: DiffPageRuntime, reload: @escaping @MainActor () -> Void) {
        guard chatPatch else { return }
        let previous = reshowing
        previous?.cancel()
        // task-owner: one reload of this tab's chat patch, after the one before it; ends when the page reloads or a newer patch takes over
        reshowing = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            await self.retire()
            guard !Task.isCancelled, !self.isClosed else { return }
            self.ready = runtime.prepare(chatPatch: patch)
            reload()
        }
    }
}
