import Foundation

/// The chat menu's Add Files to Project (cx-ncc.67, Claude desktop's project knowledge):
/// `project.addFiles` with `{cwd, name}`. After a real click in the pane, the files the user picks
/// in the open panel are copied into the chat folder's `.cmux/context/` (a taken name gets a
/// number; nothing is overwritten) and named in its instructions file, so every chat there reads
/// them: an `@` import in CLAUDE.md, a line to read in AGENTS.md (it has no imports). The file is
/// created when missing and opens in a tab, where the user sees and edits the list. It answers
/// `{added, path}`; a cancelled pick answers `{added: []}` and changes nothing. It needs a chat on
/// this Mac and `cwd` inside the pane's folders; a `.cmux` or instructions file that links out of
/// the folder is refused before the panel opens.
enum AgentPaneProjectFiles {
    /// Where the copies go, relative to the chat folder.
    static let directory = ".cmux/context"
    static let copyFailedMessage = "The files could not be added to the project."

    /// The chat menu's project requests: Edit CLAUDE.md and Add Files to Project.
    @MainActor static func respond(to request: AgentPaneRequest, in model: AgentPaneModel) async -> [String: Any] {
        switch request {
        case .projectInstructions(let instructions): return await AgentPaneProjectInstructions.reply(to: instructions, in: model)
        case .projectAddFiles(let files): return await reply(to: files, in: model)
        default: return AgentPaneModel.unsupported(String(describing: request))
        }
    }

    /// `project.addFiles` (nil: params that break the contract).
    @MainActor static func reply(to request: AgentPaneProjectInstructions?, in model: AgentPaneModel) async -> [String: Any] {
        guard let request else { return AgentPaneModel.transportFailure(.pathInvalid) }
        guard !model.remoteChat, let onChooseFiles = model.onChooseFiles else { return AgentPaneModel.unsupported("project.addFiles") }
        let roots = model.fileOpenRoots()
        let folder: String
        switch request.folder(roots: roots) {
        case .success(let canonical): folder = canonical
        case .failure(let refusal): return AgentPaneModel.transportFailure(refusal)
        }
        let instructions = URL(fileURLWithPath: folder).appendingPathComponent(request.name)
        if let refusal = contextRefusal(folder) ?? (exists(instructions.path) ? check(instructions, request.name, roots).refusal : nil) {
            return AgentPaneModel.transportFailure(refusal)
        }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }

        let picks = await onChooseFiles()
        guard !picks.isEmpty else { return AgentPaneReply.success(["added": [String]()]) }
        let context = URL(fileURLWithPath: folder).appendingPathComponent(directory)
        guard (try? FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)) != nil else {
            return AgentPaneReply.failure(code: "copy_failed", message: copyFailedMessage)
        }
        // Checked again once made: a link put there while the panel was up is refused.
        if let refusal = contextRefusal(folder) { return AgentPaneModel.transportFailure(refusal) }
        let added = picks.compactMap { copy($0, into: context) }.map { "\(directory)/\($0)" }
        guard !added.isEmpty else { return AgentPaneReply.failure(code: "copy_failed", message: copyFailedMessage) }

        // Exclusive create: a file (or link) already there is kept, then checked as it resolves.
        _ = try? Data().write(to: instructions, options: .withoutOverwriting)
        let url: URL
        switch check(instructions, request.name, roots) {
        case .success(let resolved): url = resolved
        case .failure(let refusal): return AgentPaneModel.transportFailure(refusal)
        }
        let lines = added.map { request.name == "CLAUDE.md" ? "@\($0)" : "Read `\($0)` for project context." }
        guard append(lines, to: url) else { return AgentPaneReply.failure(code: "copy_failed", message: copyFailedMessage) }
        guard let onOpenFile = model.onOpenFile, await onOpenFile(url, .tab) else {
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

    /// The instructions file as it resolves: a regular file under a root that keeps its name.
    private static func check(_ file: URL, _ name: String, _ roots: [String]) -> Result<URL, AgentPaneTransportError> {
        AgentPaneFileOpen.resolve(file.path, roots: roots).flatMap { url in
            url.lastPathComponent == name ? .success(url) : .failure(.pathInvalid)
        }
    }

    /// Copies a picked file into `context` under a name a harness can import (no spaces), with a
    /// number when taken; nil for a folder or a copy that failed.
    private static func copy(_ source: URL, into context: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let name = source.lastPathComponent.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for number in 1...999 {
            let candidate = number == 1 ? name : (ext.isEmpty ? "\(stem)-\(number)" : "\(stem)-\(number).\(ext)")
            let destination = context.appendingPathComponent(candidate)
            if exists(destination.path) { continue }
            // copyItem never replaces: a file made there meanwhile fails the copy.
            return (try? FileManager.default.copyItem(at: source, to: destination)) != nil ? candidate : nil
        }
        return nil
    }

    /// Appends `lines` to the file, after a newline when its text does not end in one.
    private static func append(_ lines: [String], to url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            var text = lines.joined(separator: "\n") + "\n"
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data("\n".utf8) { text = "\n" + text }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
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
