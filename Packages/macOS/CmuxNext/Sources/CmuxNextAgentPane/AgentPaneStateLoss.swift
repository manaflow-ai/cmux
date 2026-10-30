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

    /// Red-proof ref: nothing is logged or recorded.
    func keep(_ names: [String]) {}

    /// Red-proof ref: no record is kept.
    public func lastQuitNames() -> [String] { [] }

    public func pairedCutOffSettled() {}

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
    public static func notices(for names: [String], pairedSealCleared: Bool) -> [String] { [] }

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
