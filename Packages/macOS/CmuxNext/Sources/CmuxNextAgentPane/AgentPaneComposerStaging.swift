import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Local clipboard bytes, independent of where the chat runs. The page sees opaque references,
/// never authority to read an arbitrary local path. Stages and completed references belong to one
/// pane/session generation; one deadline removes abandoned completed files.
@MainActor
final class AgentPaneComposerStaging {
    private struct Target {
        var owner: UUID
        var revision: UUID
    }
    private struct Reference {
        var target: Target
        var file: URL
        var expires: Date
        var taken = false
    }

    private let stages = AgentPaneStagedUploads<Target>(owner: "composer-copy-stages")
    private let expiry = DemandTimer(owner: "composer-copy-references")
    private var references: [String: Reference] = [:]
    private var activeUntil = Date.distantPast
    private var finishing: Set<String> = []
    private var cancelled: Set<String> = []

    func respond(_ request: AgentPaneUploadStageRequest, in model: AgentPaneModel) async -> [String: Any] {
        guard let work = model.replyLinks.copyWork else { return AgentPaneModel.replyFailure(.openFailed) }
        let owner = model.droppedPaths.generation
        activeUntil = Date().addingTimeInterval(AgentPaneStagedUploads<UUID>.lifetime)
        let owns: (Target) -> Bool = { $0.owner == model.droppedPaths.generation && $0.revision == model.replyLinks.composerCopyRevision }
        let folder = model.replyLinks.imageFolder.appendingPathComponent("Composer Copies", isDirectory: true)
        switch request {
        case .begin(let name, let size, let batchToken, let manifest):
            guard AgentPaneStagedUploads<Target>.acceptsBegin(name: name, size: size, manifest: manifest) else {
                return AgentPaneModel.replyFailure(.openFailed)
            }
            if let batchToken {
                guard let target = stages.batchTarget(batchToken, name: name, size: size), owns(target) else {
                    return AgentPaneModel.replyFailure(.gestureRequired)
                }
            } else {
                guard model.transport.gestures.consume() else { return AgentPaneModel.replyFailure(.gestureRequired) }
                model.replyLinks.composerCopyRevision = UUID()
            }
            let target = Target(owner: owner, revision: model.replyLinks.composerCopyRevision)
            let place = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let file = place.appendingPathComponent(name)
            guard (try? await work.run(.userBlocking, mayBlock: .files, { () throws -> Void in
                try FileManager.checked.createDirectory(at: place, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard FileManager.checked.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            })) != nil else { return AgentPaneModel.replyFailure(.openFailed) }
            guard owns(target), let stage = stages.begin(name: name, size: size, batchToken: batchToken, manifest: manifest,
                                                       target: target, work: work, make: { _ in (file, place) }) else {
                _ = try? await work.run(.userBlocking, mayBlock: .files) { try? FileManager.checked.removeItem(at: place) }
                return AgentPaneModel.replyFailure(.openFailed)
            }
            var answer: [String: Any] = ["token": stage.token, "chunkSize": AgentPaneStagedUploads<Target>.chunkBytes]
            if let batchToken = stage.batchToken { answer["batchToken"] = batchToken }
            return AgentPaneReply.success(answer)
        case .chunk(let token, let offset, let data):
            let revision = model.replyLinks.composerCopyRevision
            guard let next = await stages.append(token, offset: offset, data: data, owns: owns, work: work),
                  model.droppedPaths.generation == owner, model.replyLinks.composerCopyRevision == revision else {
                return AgentPaneModel.replyFailure(.openFailed)
            }
            return AgentPaneReply.success(["offset": next])
        case .finish(let token):
            guard !finishing.contains(token) else { return AgentPaneModel.replyFailure(.openFailed) }
            finishing.insert(token)
            defer { finishing.remove(token); cancelled.remove(token) }
            let target = Target(owner: owner, revision: model.replyLinks.composerCopyRevision)
            let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("payload")
            let finished = await stages.finish(token, owns: owns, work: work, transfer: { staged -> URL? in
                guard (try? await work.run(.userBlocking, mayBlock: .files, { () throws -> Void in
                    try FileManager.checked.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    try FileManager.checked.moveItem(at: staged.file, to: destination)
                })) != nil else { return nil }
                return destination
            }, undo: { [weak self, weak model] _ in {
                if model?.replyLinks.composerCopyRevision == target.revision { model?.replyLinks.composerCopyRevision = UUID() }
                await self?.remove(token, work: work)
            } })
            guard let file = finished ?? nil else { return AgentPaneModel.replyFailure(.openFailed) }
            references[token] = Reference(target: target, file: file, expires: Date().addingTimeInterval(AgentPaneStagedUploads<Target>.lifetime))
            arm(work)
            guard owns(target), !Task.isCancelled, !cancelled.contains(token) else {
                await remove(token, work: work)
                return AgentPaneModel.replyFailure(.openFailed)
            }
            return AgentPaneReply.success(["reference": token])
        case .cancel(let token):
            if finishing.contains(token) { cancelled.insert(token) }
            await stages.cancel(token, owns: { $0.owner == owner }, work: work)
            if references[token]?.target.owner == owner { await remove(token, work: work) }
            return AgentPaneReply.success()
        }
    }

    /// Atomically consumes the references for a copy. Files successfully published on a clipboard
    /// remain available there; a token cannot authorize another copy or cross a session switch.
    func take(_ tokens: [String], owner: UUID, revision: UUID, work: BackgroundWork) -> [String: URL]? {
        let now = Date()
        guard Set(tokens).count == tokens.count,
              tokens.allSatisfy({ references[$0].map { !$0.taken && $0.target.owner == owner && $0.target.revision == revision && max($0.expires, activeUntil) > now } == true }) else { return nil }
        var files: [String: URL] = [:]
        for token in tokens {
            files[token] = references[token]?.file
            references[token]?.taken = true
        }
        arm(work)
        return files
    }

    /// Settles the single-use lease after the clipboard write. Only published attachment files
    /// remain; selection/metadata and every failed copy are unlinked on the file lane.
    func published(_ tokens: Set<String>) {
        // This runs in the clipboard commit's turn, before a cancel can unlink a published file.
        for token in tokens { references.removeValue(forKey: token) }
    }

    func settle(_ tokens: [String], work: BackgroundWork) async {
        for token in tokens { await remove(token, work: work) }
        arm(work)
    }

    private func remove(_ token: String, work: BackgroundWork) async {
        guard let ref = references.removeValue(forKey: token) else { return }
        arm(work)
        let place = ref.file.deletingLastPathComponent()
        // task-owner: one unlink retained through cancellation and shutdown, awaited to settlement.
        await Task { @MainActor in
            _ = try? await work.run(.userBlocking, mayBlock: .files, shutdown: .blockShutdown) { try? FileManager.checked.removeItem(at: place) }
        }.value
    }

    private func arm(_ work: BackgroundWork) {
        guard let deadline = references.values.filter { !$0.taken }.map(\.expires).min() else { expiry.cancel(); return }
        expiry.schedule(after: .seconds(max(1, max(deadline, activeUntil).timeIntervalSinceNow))) { @MainActor [weak self] in
            // task-owner: one deadline cleanup; it ends after removing the expired references.
            Task { @MainActor [weak self] in
                guard let self else { return }
                for token in references.filter({ !$0.value.taken && max($0.value.expires, activeUntil) <= Date() }).map(\.key) { await remove(token, work: work) }
                arm(work)
            }
        }
    }
}
