import Foundation

/// The chat menu's Add Files to Project (cx-ncc.67, Claude desktop's project knowledge):
/// `project.addFiles` with `{cwd, name}`. After a real click in the pane, the files the user picks
/// in the open panel are copied into the chat folder's `.cmux/context/` (a taken name gets a
/// number; nothing is overwritten) and named in its instructions file, so every chat there reads
/// them: an `@` import in CLAUDE.md, a line to read in AGENTS.md (it has no imports). The file is
/// created when missing and opens in a tab, where the user sees and edits the list. It answers
/// `{added, path}`; a cancelled pick answers `{added: []}` and changes nothing. It needs a chat on
/// this Mac and `cwd` inside the pane's folders; a `.cmux` that links out of the folder, or an
/// instructions file that is not the folder's own, is refused before the panel opens. The writes
/// (``AgentPaneProjectCopy``) never follow a link put there meanwhile.
enum AgentPaneProjectFiles {
    /// Where the copies go, relative to the chat folder.
    static let directory = ".cmux/context"
    static let copyFailedMessage = "The files could not be added to the project."

    /// The requests that open a system picker after a click: the chat menu's Edit CLAUDE.md and Add
    /// Files to Project, and the composer's Attach Screenshot… and Attach Window….
    @MainActor static func respond(to request: AgentPaneRequest, in model: AgentPaneModel) async -> [String: Any] {
        switch request {
        case .projectInstructions(let instructions): return await AgentPaneProjectInstructions.reply(to: instructions, in: model)
        case .projectAddFiles(let files): return await reply(to: files, in: model)
        case .composerCapture(let mode): return await AgentPaneCapture.reply(to: mode, in: model)
        default: return AgentPaneModel.unsupported(String(describing: request))
        }
    }

    /// `project.addFiles` (nil: params that break the contract).
    @MainActor static func reply(to request: AgentPaneProjectInstructions?, in model: AgentPaneModel) async -> [String: Any] {
        guard let request else { return AgentPaneModel.transportFailure(.pathInvalid) }
        guard !model.remoteChat, let onChooseFiles = model.onChooseFiles else { return AgentPaneModel.unsupported("project.addFiles") }
        let folder: String
        switch request.folder(roots: model.fileOpenRoots()) {
        case .success(let canonical): folder = canonical
        case .failure(let refusal): return AgentPaneModel.transportFailure(refusal)
        }
        let instructions = URL(fileURLWithPath: folder).appendingPathComponent(request.name)
        if let refusal = contextRefusal(folder) ?? (exists(instructions.path) ? check(instructions, folder).refusal : nil) {
            return AgentPaneModel.transportFailure(refusal)
        }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }

        let picks = await onChooseFiles()
        guard !picks.isEmpty else { return AgentPaneReply.success(["added": [String]()]) }
        let sources = await Task.detached { AgentPaneProjectCopy.regularFiles(picks) }.value
        guard !sources.isEmpty else { return AgentPaneReply.failure(code: "copy_failed", message: copyFailedMessage) }
        // The file to name them in first, so a refusal leaves no copies behind. Exclusive create: a
        // file (or link) already there is kept, then checked as it resolves.
        _ = try? Data().write(to: instructions, options: .withoutOverwriting)
        let url: URL
        switch check(instructions, folder) {
        case .success(let resolved): url = resolved
        case .failure(let refusal): return AgentPaneModel.transportFailure(refusal)
        }
        guard let names = await Task.detached(operation: { AgentPaneProjectCopy.copy(sources, into: folder) }).value else {
            return AgentPaneModel.transportFailure(.pathOutsideRoots)
        }
        let added = names.map { "\(directory)/\($0)" }
        guard !added.isEmpty else { return AgentPaneReply.failure(code: "copy_failed", message: copyFailedMessage) }
        // `@` imports only when CLAUDE.md resolves to itself: Codex reads AGENTS.md and ignores
        // imports, so a file shared through a link (either way) gets plain lines both agents read.
        let imports = request.name == "CLAUDE.md" && url.lastPathComponent == "CLAUDE.md"
        let lines = added.map { imports ? "@\($0)" : "Read `\($0)` for project context." }
        let path = url.path
        guard await Task.detached(operation: { AgentPaneProjectCopy.append(lines, to: path) }).value else {
            return AgentPaneReply.failure(code: "copy_failed", message: copyFailedMessage)
        }
        guard let onOpenFile = model.onOpenFile, await onOpenFile(url, .tab, nil) else {
            return AgentPaneReply.failure(code: "open_failed", message: AgentPaneModel.openFileFailedMessage)
        }
        return AgentPaneReply.success(["added": added, "path": url.path])
    }

    /// Whether anything (a link too) is at `path`.
    private static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// A refusal when `.cmux` or `.cmux/context` exists but is not a folder inside `folder` (a link out).
    private static func contextRefusal(_ folder: String) -> AgentPaneTransportError? {
        for relative in [".cmux", directory] {
            let path = folder + "/" + relative
            guard exists(path) else { return nil }
            guard let canonical = AcpmuxPathPolicy.canonical(path), AcpmuxPathPolicy.contains(root: folder, path: canonical) else {
                return .pathOutsideRoots
            }
            guard AcpmuxPathPolicy.isDirectory(canonical) else { return .pathInvalid }
        }
        return nil
    }

    /// The instructions file as it resolves: a regular file directly in the chat folder (not a
    /// subfolder or another of the pane's folders: the added paths are relative to the chat folder)
    /// named CLAUDE.md or AGENTS.md, so a file that links to the other one gets the lines.
    private static func check(_ file: URL, _ folder: String) -> Result<URL, AgentPaneTransportError> {
        AgentPaneFileOpen.resolve(file.path, roots: [folder]).flatMap { url in
            AgentPaneProjectInstructions.names.contains(url.lastPathComponent)
                && url.deletingLastPathComponent().path == AcpmuxPathPolicy.canonical(folder)
                ? .success(url) : .failure(.pathInvalid)
        }
    }
}

private extension Result {
    /// The failure, nil on success.
    var refusal: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
