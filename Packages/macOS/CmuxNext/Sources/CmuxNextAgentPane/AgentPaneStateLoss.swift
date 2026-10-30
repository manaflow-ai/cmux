public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import Darwin
import os

/// The state files a quit ended without saving (the agent panes', the paired phones' list), so the next launch can say so (R9 review of
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
    /// the files of `files` still saving and those `alsoCutOff` names (it may act on them first: the
    /// paired phones' list fails closed), then runs `end` (the process's end; tests pass their own).
    public func deadlineEnd(files: AgentPaneStateFiles, alsoCutOff: @escaping @Sendable () -> [String] = { [] },
                            end: (@Sendable () -> Void)? = nil) -> @Sendable () -> Void {
        let end = end ?? { _exit(0) }
        return { [self] in
            keep(files.savingFileNames() + alsoCutOff())
            end()
        }
    }

    /// Logs and records `names`; nothing when it is empty.
    func keep(_ names: [String]) {
        guard !names.isEmpty else { return }
        Self.logger.fault("quit ended with state files still saving: \(names.joined(separator: ", "), privacy: .public)")
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

    /// The paired phones' list (`MobileHostPairedDevicesFile.fileName`; QuitStateFilesTests checks they match).
    public static let pairedPhonesFileName = "paired-devices.json"

    /// The notices for `names`: a new chat's unsent text, and a paired-phones change (that list failed
    /// closed, so every phone pairs again). A scroll place comes back by itself at the next scroll.
    @MainActor
    public static func notices(for names: [String]) -> [String] {
        var notices: [String] = []
        if names.contains(AgentUnsentDrafts.fileName) {
            notices.append(String(localized: "agentPane.stateLoss.unsentDraft",
                                  defaultValue: "Text typed in a new chat just before cmux quit was not saved.", bundle: .module))
        }
        if names.contains(pairedPhonesFileName) {
            logger.error("the last quit cut off a paired-phones save; no stored list counts, every phone pairs again")
            notices.append(String(localized: "agentPane.stateLoss.pairedPhones",
                                  defaultValue: "A change to your paired iPhones was cut off when cmux quit. Pair your iPhones again.",
                                  bundle: .module))
        }
        return notices
    }

    /// Takes the last quit's record and shows its notices in `window`.
    @MainActor
    public func showNotice(in window: NSWindow) async {
        for (index, message) in Self.notices(for: await take()).enumerated() {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "state-lost-\(index)", message: message, duration: .seconds(12)), in: window)
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.state-files")
}
