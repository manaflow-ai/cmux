import Foundation

/// The chat menu's Edit CLAUDE.md / Edit AGENTS.md (cx-ncc.65, Claude desktop's project
/// instructions): `project.instructions` with `{cwd, name}`. The App opens the chat folder's
/// instructions file in a file tab, where it is edited and saved, and creates it empty first when
/// the folder has none (an existing file is never overwritten). It answers `{path, created}`. It
/// needs a real click or key in the pane, a chat on this Mac and `cwd` inside the pane's folders.
public nonisolated struct AgentPaneProjectInstructions: Equatable, Sendable {
    /// The files a harness reads its project instructions from.
    static let names: Set<String> = ["CLAUDE.md", "AGENTS.md"]

    /// The chat's folder, absolute.
    public let cwd: String
    /// `CLAUDE.md` or `AGENTS.md`.
    public let name: String

    public init?(params: [String: Any]?) {
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"),
              let name = params?["name"] as? String, Self.names.contains(name) else { return nil }
        self.cwd = cwd
        self.name = name
    }

    /// `project.instructions` (nil: params that break the contract): spends `model`'s gesture,
    /// then creates the file when missing and opens it in a tab.
    @MainActor static func reply(to request: AgentPaneProjectInstructions?, in model: AgentPaneModel) async -> [String: Any] {
        guard let request else { return AgentPaneModel.transportFailure(.pathInvalid) }
        guard !model.remoteChat else { return AgentPaneModel.unsupported("project.instructions") }
        let roots = model.fileOpenRoots()
        let folder: String
        switch request.folder(roots: roots) {
        case .success(let canonical): folder = canonical
        case .failure(let refusal): return AgentPaneModel.transportFailure(refusal)
        }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        let file = URL(fileURLWithPath: folder).appendingPathComponent(request.name)
        // Exclusive create: a file (or link) already there is kept as it is.
        let created = (try? Data().write(to: file, options: .withoutOverwriting)) != nil
        // The file, made canonical, must still be a regular file under a root (a link out is refused)
        // named CLAUDE.md or AGENTS.md: a committed CLAUDE.md that links to a page (x.html) never opens it.
        // A refusal or a tab that can't open takes back the empty file it made, only while it is
        // still that: an empty regular file (`attributesOfItem` reads a link, not its target).
        let undo = {
            guard created, let item = try? FileManager.default.attributesOfItem(atPath: file.path),
                  item[.type] as? FileAttributeType == .typeRegular, (item[.size] as? NSNumber)?.intValue == 0 else { return }
            try? FileManager.default.removeItem(at: file)
        }
        let url: URL
        switch AgentPaneFileOpen.resolve(file.path, roots: roots) {
        case .success(let resolved): url = resolved
        case .failure(let refusal):
            undo()
            return AgentPaneModel.transportFailure(refusal)
        }
        // Either instructions name: a CLAUDE.md that links to the folder's AGENTS.md opens that.
        guard names.contains(url.lastPathComponent) else {
            undo()
            return AgentPaneModel.transportFailure(.pathInvalid)
        }
        guard let onOpenFile = model.onOpenFile, await onOpenFile(url, .tab, nil) else {
            undo()
            return AgentPaneReply.failure(code: "open_failed", message: AgentPaneModel.openFileFailedMessage)
        }
        return AgentPaneReply.success(["path": url.path, "created": created])
    }

    /// The chat's folder made canonical: an existing folder inside one of `roots`.
    func folder(roots: [String]) -> Result<String, AgentPaneTransportError> {
        let canonicalRoots = roots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        var isDirectory: ObjCBool = false
        guard let folder = AcpmuxPathPolicy.canonical(cwd),
              FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.pathInvalid)
        }
        guard canonicalRoots.contains(where: { AcpmuxPathPolicy.contains(root: $0, path: folder) }) else {
            return .failure(.pathOutsideRoots)
        }
        return .success(folder)
    }
}
