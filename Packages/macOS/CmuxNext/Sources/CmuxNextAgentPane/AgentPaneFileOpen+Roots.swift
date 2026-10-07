import Foundation

extension AgentPaneFileOpen {
    /// The file `path` names for the page's `file.open`, or why it is refused. The path comes from
    /// reply text and tool calls, so it is made canonical first (`realpath`: symlinks and `..`
    /// resolved) and must then be under one canonical root, by path components, the same rule as
    /// the relay's frames (``AcpmuxPathPolicy``). A root of `/` counts as no root.
    static func resolve(_ path: String, roots: [String]) -> Result<URL, AgentPaneTransportError> {
        guard let canonical = AcpmuxPathPolicy.canonical(path) else { return .failure(.pathInvalid) }
        let canonicalRoots = roots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        guard canonicalRoots.contains(where: { AcpmuxPathPolicy.contains(root: $0, path: canonical) }) else {
            return .failure(.pathOutsideRoots)
        }
        guard resolve(canonical) != nil else { return .failure(.pathInvalid) }
        return .success(URL(fileURLWithPath: canonical))
    }
}

extension AgentPaneModel {
    /// The folders a page's `file.open` may name a file under: the pane's own roots and the
    /// folders the user added to it (the add-folder sheet).
    func fileOpenRoots() -> [String] {
        roots() + transport.addedRoots + sessionRoots()
    }

    /// The active session's own folder (the cwd the daemon reported for it), when the session is
    /// in the pane's scope (the pane started it or the user opened it here). Never `/` or the home
    /// folder, which would make every file a root.
    func sessionRoots() -> [String] {
        guard let id = sessionId, transport.sessions.contains(id), let folder = transport.sessions.folder(of: id),
              let canonical = AcpmuxPathPolicy.canonical(folder), canonical != "/",
              canonical != (AcpmuxPathPolicy.canonical(NSHomeDirectory()) ?? NSHomeDirectory()) else { return [] }
        return [canonical]
    }

    /// The file a page's `file.open` may open for `target`, or the refusal: under a root
    /// (``AgentPaneFileOpen/resolve(_:roots:)``), a type the target may show, and a real user
    /// gesture in the pane, spent by this open (page script cannot make one).
    func checkedFileOpen(_ path: String, target: AgentPaneFileTarget) -> Result<URL, AgentPaneTransportError> {
        AgentPaneFileOpen.resolve(path, roots: fileOpenRoots()).flatMap { url in
            guard target == .editor || AgentPaneFileOpen.showsInTab(url) else { return .failure(.pathInvalid) }
            return transport.gestures.consume() ? .success(url) : .failure(.gestureRequired)
        }
    }
}
