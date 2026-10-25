import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation

/// The files a kind of chat (this Mac's, an ssh peer's) is streaming in chunks
/// (``AgentPaneUploadStageRequest``): which chat and upload each token names, the batch a page
/// announced with its first file, and one deadline for the earliest expiry (an upload whose page
/// went away without a cancel). A chunk only moves its upload's expiry date: no timer or task per
/// chunk (plans/cmux-next/idle-wakeups.md).
@MainActor
final class AgentUploadStages<Upload: Sendable> {
    struct Stage {
        var session: String
        var name: String
        var size: Int
        var upload: Upload
        var expires: Date
    }

    /// Whether a file may start: the page's batch (or none) names it next. `batchToken` is the token
    /// the reply carries for the batch's next files.
    enum Admission: Equatable {
        case admitted(batchToken: String?)
        case refused
    }

    private struct Batch { var session: String; var remaining: [AgentPaneUploadBatchEntry]; var expires: Date }

    /// How long an upload waits for its next chunk, and a batch for its next file.
    nonisolated static var lifetime: TimeInterval { 10 * 60 }
    private var stages: [String: Stage] = [:]
    private var batches: [String: Batch] = [:]
    private let timer: DemandTimer
    private let now: () -> Date
    private let expire: @MainActor (Upload) -> Void

    /// - Parameter expire: what goes with an upload past its expiry (its partial file).
    init(owner: String, now: @escaping () -> Date = Date.init, expire: @escaping @MainActor (Upload) -> Void) {
        timer = DemandTimer(owner: owner)
        self.now = now
        self.expire = expire
    }

    /// Admits file `name` of `size` bytes into chat `session`: the next file of batch `batchToken`,
    /// or the first of the files `manifest` lists (the reply then names the batch for the rest).
    func admit(name: String, size: Int, batchToken: String?, manifest: [AgentPaneUploadBatchEntry]?, session: String) -> Admission {
        let now = now()
        batches = batches.filter { $0.value.expires >= now }
        if let batchToken {
            guard let batch = batches[batchToken], batch.session == session,
                  batch.remaining.first == AgentPaneUploadBatchEntry(name: name, size: size) else { return .refused }
            let remaining = Array(batch.remaining.dropFirst())
            batches[batchToken] = remaining.isEmpty ? nil : Batch(session: session, remaining: remaining, expires: now.addingTimeInterval(Self.lifetime))
            return .admitted(batchToken: nil)
        }
        guard let manifest else { return .admitted(batchToken: nil) }
        guard manifest.first == AgentPaneUploadBatchEntry(name: name, size: size) else { return .refused }
        guard manifest.count > 1 else { return .admitted(batchToken: nil) }
        let id = UUID().uuidString.lowercased()
        batches[id] = Batch(session: session, remaining: Array(manifest.dropFirst()), expires: now.addingTimeInterval(Self.lifetime))
        return .admitted(batchToken: id)
    }

    /// Starts `upload` of file `name` for chat `session`; answers its token.
    func add(_ upload: Upload, name: String, size: Int, session: String) -> String {
        let token = UUID().uuidString.lowercased()
        stages[token] = Stage(session: session, name: name, size: size, upload: upload, expires: now().addingTimeInterval(Self.lifetime))
        arm()
        return token
    }

    /// Upload `token` of chat `session`, its expiry moved on (a chunk came).
    func stage(_ token: String, session: String) -> Stage? {
        guard var stage = stages[token], stage.session == session else { return nil }
        stage.expires = now().addingTimeInterval(Self.lifetime)
        stages[token] = stage
        return stage
    }

    /// Ends upload `token` of chat `session` (finished or cancelled); the caller ends its file.
    @discardableResult
    func remove(_ token: String, session: String) -> Stage? {
        guard let stage = stages[token], stage.session == session else { return nil }
        stages[token] = nil
        if stages.isEmpty { timer.cancel() }
        return stage
    }

    /// The uploads in flight (tests).
    var count: Int { stages.count }

    /// Ends every upload past its expiry, then waits for the next one's (the deadline's work; tests
    /// call it with their own clock). A new upload expires last and a chunk only pushes an expiry
    /// later, so the pending deadline is never late.
    func expireDue() {
        let now = now()
        for (token, stage) in stages where stage.expires <= now {
            stages[token] = nil
            expire(stage.upload)
        }
        arm()
    }

    private func arm() {
        guard let next = stages.values.map(\.expires).min() else { timer.cancel(); return }
        guard !timer.isScheduled else { return }
        timer.schedule(after: .seconds(max(1, next.timeIntervalSince(now())))) { @MainActor [weak self] in
            self?.expireDue()
        }
    }
}
