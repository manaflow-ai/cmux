public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import Darwin
import os

/// The state files a quit ended without saving (the agent panes', the paired phones' list), so the next launch can say so (R9 review of
/// cmux#28275). A quit awaits their queued saves with no limit of its own, after its deadline is armed;
/// when that deadline ends the process first, its end (``deadlineEnd(files:end:)``) logs a fault naming
/// the files still queued (names only, never content) and records them in `<state>/agent-state-lost.json`.
/// The next launch reads the record once (``lastQuitNames()``): the paired phones' list checks it before
/// its first read, and a new chat's lost unsent text earns a notice. The record keeps naming the paired
/// list until that list says the fact is safe (``pairedCutOffSettled()``): the record may be its only copy.
public nonisolated final class AgentPaneStateLoss: Sendable {
    public static let fileName = "agent-state-lost.json"
    /// The record; nil keeps none (a test host).
    public let record: URL?
    /// The last quit's names, read once from the record; nil until read. `pending`: the paired list's
    /// names the record keeps until ``pairedCutOffSettled()``.
    private let state = Mutex<(lastQuit: [String]?, pending: [String])>((nil, []))

    /// - Parameter directory: The tag's state directory (beside the launch snapshot).
    public init(directory: URL?) {
        record = directory?.appending(path: Self.fileName)
    }

    /// A quit deadline's end (`QuitDeadline(end:)`), run on the deadline's own thread: names and records
    /// the files of `files` still saving and those `alsoCutOff` names (it may mark them: never a call
    /// that can hang, such as the Keychain), then runs `end` (the process's end; tests pass their own).
    public func deadlineEnd(files: AgentPaneStateFiles, alsoCutOff: @escaping @Sendable () -> [String] = { [] },
                            end: (@Sendable () -> Void)? = nil) -> @Sendable () -> Void {
        let end = end ?? { _exit(0) }
        return { [self] in
            keep(files.savingFileNames() + alsoCutOff())
            end()
        }
    }

    /// Logs and records `names`, with the paired list's names the record still keeps; nothing when
    /// `names` is empty (the record on disk then still names those).
    func keep(_ names: [String]) {
        guard !names.isEmpty else { return }
        Self.logger.fault("quit ended with state files still saving: \(names.joined(separator: ", "), privacy: .public)")
        state.withLock { state in
            write(names + state.pending.filter { !names.contains($0) })
        }
    }

    /// The names the last quit recorded; empty when none. The first call (from any thread but the main
    /// one: it reads the disk) reads the record, and every later call gets the same names. The record is
    /// removed then, except when it names a cut-off paired list: it keeps naming only that list until
    /// ``pairedCutOffSettled()`` (a crash before the list's own launch step loses nothing).
    public func lastQuitNames() -> [String] {
        state.withLock { state in
            if let cached = state.lastQuit { return cached }
            let names = record.flatMap { try? Data(blockingContentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let paired = names.filter(Self.isPaired)
            state.lastQuit = names
            state.pending = paired
            if names != paired { write(paired) }
            return names
        }
    }

    /// The paired list made the cut-off fact safe (its marker is on disk, or its seal is cleared): the
    /// record stops naming it, and is removed when it names nothing else.
    public func pairedCutOffSettled() {
        state.withLock { state in
            guard !state.pending.isEmpty else { return }
            let pending = state.pending
            state.pending = []
            let onDisk = record.flatMap { try? Data(blockingContentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            write(onDisk.filter { !pending.contains($0) && !Self.isPaired($0) })
        }
    }

    /// Writes `names` as the record, or removes it when `names` is empty.
    private func write(_ names: [String]) {
        guard let record else { return }
        guard !names.isEmpty else {
            try? FileManager.checked.removeItem(at: record)
            return
        }
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? data.blockingWrite(to: record, options: .atomic)
    }

    /// Whether a record name is the paired phones' list's (its name, or its note).
    private static func isPaired(_ name: String) -> Bool {
        name.hasPrefix("paired-devices.")
    }

    /// ``lastQuitNames()`` off the calling thread.
    public func take() async -> [String] {
        await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .utility).async { [self] in done.resume(returning: lastQuitNames()) }
        }
    }

    /// Whether the last quit cut off a paired-phones save (the paired list then fails closed at launch,
    /// also when its own marker could not be written). Off the main thread.
    public func lastQuitCutOffPairedPhones() -> Bool {
        lastQuitNames().contains(Self.pairedPhonesFileName)
    }

    /// The paired phones' list (`MobileHostPairedDevicesFile.fileName`; QuitStateFilesTests checks they match).
    public static let pairedPhonesFileName = "paired-devices.json"

    /// The notices for the last quit's `names`: a new chat's unsent text, and, when this launch cleared
    /// the paired list's seal for a save that quit cut off (`pairedSealCleared`), that every phone pairs
    /// again. A scroll place comes back by itself at the next scroll.
    @MainActor
    public static func notices(for names: [String], pairedSealCleared: Bool) -> [String] {
        var notices: [String] = []
        if names.contains(AgentUnsentDrafts.fileName) {
            notices.append(String(localized: "agentPane.stateLoss.unsentDraft",
                                  defaultValue: "Text typed in a new chat just before cmux quit was not saved.", bundle: .module))
        }
        if names.contains(pairedPhonesFileName) {
            logger.error("the last quit cut off a paired-phones save (seal cleared at launch: \(pairedSealCleared, privacy: .public))")
        }
        if pairedSealCleared {
            notices.append(String(localized: "agentPane.stateLoss.pairedPhones",
                                  defaultValue: "A change to your paired iPhones was cut off when cmux quit. Pair your iPhones again.",
                                  bundle: .module))
        }
        return notices
    }

    /// Shows the last quit's notices in `window`: the unsent-draft notice at once, and the pair-again
    /// notice once `pairedSealCleared` answers that this launch cleared the seal (a slow Keychain never
    /// holds the draft notice back).
    @MainActor
    public func showNotices(in window: NSWindow, pairedSealCleared: @escaping @MainActor () async -> Bool) async {
        for message in Self.notices(for: await take(), pairedSealCleared: false) {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "state-lost-draft", message: message, duration: .seconds(12)), in: window)
        }
        guard await pairedSealCleared() else { return }
        for message in Self.notices(for: [], pairedSealCleared: true) {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "state-lost-paired", message: message, duration: .seconds(12)), in: window)
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.state-files")
}
