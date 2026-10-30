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

    /// Red-proof ref: nothing is logged or recorded.
    func keep(_ names: [String]) {}

    /// Red-proof ref: no record is kept.
    public func take() async -> [String] { [] }

    /// The paired phones' list (`MobileHostPairedDevicesFile.fileName`; QuitStateFilesTests checks they match).
    public static let pairedPhonesFileName = "paired-devices.json"

    /// The notices for `names`: a new chat's unsent text, and a paired-phones change (that list failed
    /// closed, so every phone pairs again). A scroll place comes back by itself at the next scroll.
    @MainActor
    public static func notices(for names: [String]) -> [String] { [] }

    /// Takes the last quit's record and shows its notices in `window`.
    @MainActor
    public func showNotice(in window: NSWindow) async {
        for (index, message) in Self.notices(for: await take()).enumerated() {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "state-lost-\(index)", message: message, duration: .seconds(12)), in: window)
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.state-files")
}
