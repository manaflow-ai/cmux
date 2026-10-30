public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import Darwin
import os

/// The agent panes' state files a quit ended without saving, so the next launch can say so (R9 review of
/// cmux#28275). A quit awaits their queued saves with no limit of its own, after its deadline is armed;
/// when that deadline ends the process first, its end (``deadlineEnd(files:end:)``) logs a fault naming
/// the files still queued (names only, never content) and records them in `<state>/agent-state-lost.json`.
/// The next launch takes the record and, when a new chat's unsent text was among them, shows a notice.
public nonisolated struct AgentPaneStateLoss: Sendable {
    public static let fileName = "agent-state-lost.json"
    /// The record; nil keeps none (a test host).
    public let record: URL?

    /// - Parameter directory: The tag's state directory (beside the launch snapshot).
    public init(directory: URL?) {
        record = directory?.appending(path: Self.fileName)
    }

    /// A quit deadline's end (`QuitDeadline(end:)`), run on the deadline's own thread: names and records
    /// the files of `files` still saving, then runs `end` (the process's end; tests pass their own).
    public func deadlineEnd(files: AgentPaneStateFiles, end: (@Sendable () -> Void)? = nil) -> @Sendable () -> Void {
        let end = end ?? { _exit(0) }
        return { [self] in
            recordStillSaving(files)
            end()
        }
    }

    /// Logs and records the files of `files` still saving; nothing when none is.
    public func recordStillSaving(_ files: AgentPaneStateFiles) {
        let names = files.savingFileNames()
        guard !names.isEmpty else { return }
        Self.logger.fault("quit ended with agent pane state files still saving: \(names.joined(separator: ", "), privacy: .public)")
        guard let record, let data = try? JSONEncoder().encode(names) else { return }
        try? data.blockingWrite(to: record, options: .atomic)
    }

    /// The names the last quit recorded, read and removed off the calling thread; empty when none.
    public func take() async -> [String] {
        guard let record else { return [] }
        return await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .utility).async {
                let names = (try? Data(blockingContentsOf: record)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                if !names.isEmpty { try? FileManager.checked.removeItem(at: record) }
                done.resume(returning: names)
            }
        }
    }

    /// The notice for `names`: only a new chat's unsent text is worth one (a scroll place comes back by
    /// itself at the next scroll); nil otherwise.
    @MainActor
    public static func notice(for names: [String]) -> String? {
        guard names.contains(AgentUnsentDrafts.fileName) else { return nil }
        return String(localized: "agentPane.stateLoss.unsentDraft",
                      defaultValue: "Text typed in a new chat just before cmux quit was not saved.", bundle: .module)
    }

    /// Takes the last quit's record and shows its notice in `window`, if it has one.
    @MainActor
    public func showNotice(in window: NSWindow, toasts: CmuxToastCenter = .shared) async {
        guard let message = Self.notice(for: await take()) else { return }
        _ = toasts.show(CmuxToast(id: "agent-state-lost", message: message, duration: .seconds(12)), in: window)
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.state-files")
}
