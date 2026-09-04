import AppKit
import CmuxArtifacts
import Foundation
import UniformTypeIdentifiers

/// Shared open, reveal, copy, and drag routing for every Artifacts entrypoint.
@MainActor
struct ArtifactActionRouter {
    /// Private pasteboard type carrying the stable catalog identity.
    let artifactPasteboardType = NSPasteboard.PasteboardType("com.cmux.artifact")

    /// Opens a record in the existing browser/file-preview/default-app routes.
    @discardableResult
    func open(_ record: ArtifactRecord, from workspace: Workspace) -> Bool {
        if case .unknown = record.kind {
            // Preserve/search unknown future kinds, but never guess an opener.
            return false
        }
        guard let targetWorkspace = ownerWorkspace(for: record, fallback: workspace) else { return false }
        switch record.representation {
        case .url(let value):
            guard let url = URL(string: value) else { return false }
            if url.isFileURL {
                return openFile(url, in: targetWorkspace)
            }
            let sourcePanelID = record.metadata["sourcePanelID"].flatMap(UUID.init(uuidString:))
            return TerminalLinkOpenCoordinator().open(TerminalLinkOpenRequest(
                rawValue: url.absoluteString,
                sourceWorkspaceId: targetWorkspace.id,
                sourcePanelId: sourcePanelID,
                workingDirectory: targetWorkspace.currentDirectory
            ))
        case .managedFile:
            Task { @MainActor in
                if let url = await targetWorkspace.artifactsState.materializedURL(for: record) {
                    _ = openFile(url, in: targetWorkspace)
                }
            }
            return true
        case .directory(let path):
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path),
                  !Self.isSymlink(url) else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        case .inlineHTML(let html):
            return openInlineFile(html, fileExtension: "html", in: targetWorkspace)
        case .inlineText(let text):
            return openInlineFile(text, fileExtension: "txt", in: targetWorkspace)
        }
    }

    /// Reveals a file-backed record in Finder after validating its owner.
    func reveal(_ record: ArtifactRecord, from workspace: Workspace) {
        guard let targetWorkspace = ownerWorkspace(for: record, fallback: workspace) else { return }
        switch record.representation {
        case .url(let value):
            guard let url = URL(string: value), url.isFileURL else { return }
            guard FileManager.default.fileExists(atPath: url.path), !Self.isSymlink(url) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .directory(let path):
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path), !Self.isSymlink(url) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .managedFile:
            Task { @MainActor in
                if let url = await targetWorkspace.artifactsState.materializedURL(for: record) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        case .inlineText, .inlineHTML:
            break
        }
    }

    /// Creates lazy file/URL/text representations compatible with Vault drops.
    func dragProvider(_ record: ArtifactRecord, from workspace: Workspace) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName(for: record)
        let descriptor = descriptor(for: record)
        if let descriptorData = try? JSONEncoder().encode(descriptor) {
            provider.registerDataRepresentation(
                forTypeIdentifier: artifactPasteboardType.rawValue,
                // The private descriptor is an in-process hint only. External
                // consumers receive the validated URL/file/text fallbacks
                // below, never a catalog identity they could replay later.
                visibility: .ownProcess
            ) { completion in
                completion(descriptorData, nil)
                return nil
            }
        }

        switch record.representation {
        case .url(let value):
            registerText(value, on: provider)
            if let url = URL(string: value) {
                provider.registerObject(url as NSURL, visibility: .all)
            }
        case .inlineText(let value):
            registerText(value, on: provider)
        case .inlineHTML(let value):
            registerText(value, on: provider)
            provider.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) { completion in
                completion(Data(value.utf8), nil)
                return nil
            }
        case .directory, .managedFile:
            registerFileRepresentation(record, workspace: workspace, provider: provider)
        }
        return provider
    }

    private func registerText(_ value: String, on provider: NSItemProvider) {
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(Data(value.utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(value.utf8), nil)
            return nil
        }
    }

    private func registerFileRepresentation(
        _ record: ArtifactRecord,
        workspace: Workspace,
        provider: NSItemProvider
    ) {
        let type = record.kind == .directory ? UTType.folder : UTType.fileURL
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            let task = Task { @MainActor in
                let url = await workspace.artifactsState.materializedURL(for: record)
                guard let url,
                      FileManager.default.fileExists(atPath: url.path),
                      !Self.isSymlink(url) else {
                    completion(nil, false, nil)
                    return
                }
                completion(url, false, nil)
            }
            let progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = { task.cancel() }
            progress.completedUnitCount = 1
            return progress
        }
    }

    private func descriptor(for record: ArtifactRecord) -> ArtifactDragDescriptor {
        let urlString: String?
        switch record.representation {
        case .url(let value), .directory(let value): urlString = value
        case .managedFile, .inlineText, .inlineHTML: urlString = nil
        }
        return ArtifactDragDescriptor(
            artifactID: record.id,
            suggestedFileName: suggestedName(for: record),
            urlString: urlString,
            plainText: String(decoding: Array(record.copyValue.utf8.prefix(4_096)), as: UTF8.self),
            contentTypeIdentifier: record.kind.rawValue
        )
    }

    private func suggestedName(for record: ArtifactRecord) -> String {
        switch record.representation {
        case .managedFile(_, let name): return name
        case .directory(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .url(let value): return URL(string: value)?.host ?? "artifact"
        case .inlineHTML: return "artifact.html"
        case .inlineText: return "artifact.txt"
        }
    }

    private func ownerWorkspace(for record: ArtifactRecord, fallback: Workspace) -> Workspace? {
        guard let raw = record.ownership.workspaceID,
              let id = UUID(uuidString: raw) else { return fallback }
        return AppDelegate.shared?.workspaceFor(tabId: id) ?? (id == fallback.id ? fallback : nil)
    }

    private func openFile(_ url: URL, in workspace: Workspace) -> Bool {
        guard let pane = workspace.bonsplitController.focusedPaneId else {
            return NSWorkspace.shared.open(url)
        }
        let opened = workspace.openFileSurfaces(inPane: pane, filePaths: [url.path], focus: true, reuseExisting: true)
        return !opened.isEmpty || NSWorkspace.shared.open(url)
    }

    private func openInlineFile(_ value: String, fileExtension: String, in workspace: Workspace) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try Data(value.utf8).write(to: url, options: Data.WritingOptions.atomic)
            guard let pane = workspace.bonsplitController.focusedPaneId else { return NSWorkspace.shared.open(url) }
            // FilePreview classifies `.html` as a text mode, so untrusted
            // inline markup is displayed as source rather than executed in a
            // normal browser profile. A future rich preview must use an
            // explicit script-disabled WebKit configuration.
            return !workspace.openFileSurfaces(inPane: pane, filePaths: [url.path], focus: true).isEmpty
        } catch {
            return false
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: Set([URLResourceKey.isSymbolicLinkKey])).isSymbolicLink) == true
    }
}
