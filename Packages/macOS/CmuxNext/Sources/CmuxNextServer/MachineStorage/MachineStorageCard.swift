import CmuxNextCompat
import CmuxNextDesign
import Foundation

/// What this Mac's storage card shows: the last measuring pass, the last pass that acted, the
/// pass running now and what Clean up now freed. A value; ``MachineStorageCard/spec(_:)``
/// turns it into the card's words.
nonisolated struct MachineStorageState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// A measuring pass is on its way (the card just opened, or a cleanup ended).
        case measuring
        /// A Clean up now pass is on its way.
        case cleaning
        case idle
    }

    var phase: Phase = .measuring
    /// The last measuring pass's report; nil before its answer.
    var report: WorktreeCareReport?
    /// When the last pass that acted ended (automatic or Clean up now); nil before one since the
    /// session service started.
    var lastCleanup: Date?
    /// The disk as Foundation reads the home volume, for a report without one.
    var volume: WorktreeCareReport.Disk?
    /// What this card's last Clean up now freed.
    var freed: UInt64?
    /// Why the last pass did not answer.
    var error: String?

    /// The disk the card shows: the daemon's, else the home volume's.
    var disk: WorktreeCareReport.Disk? { report?.disk ?? volume }

    /// A measuring pass's answer.
    mutating func measured(_ reply: WorktreeCareReportReply) {
        phase = .idle
        report = reply.report
        if let last = reply.last?.date { lastCleanup = max(last, lastCleanup ?? last) }
        error = nil
    }

    /// Clean up now's answer: what it freed and when; the card measures again after it.
    mutating func cleaned(_ report: WorktreeCareReport) {
        phase = .measuring
        freed = report.freed
        lastCleanup = report.date ?? lastCleanup
        error = nil
    }

    mutating func failed(_ message: String) {
        phase = .idle
        error = message
    }
}

/// This Mac's storage card (the native cmux dialog card): the disk, what cleanup could free,
/// how many worktrees it keeps and would clean up, the last cleanup, whether automatic cleanup is
/// on, and Clean up now. No confirm: cleanup never deletes work that lives only on this Mac (it is
/// archived first) and a cleaned worktree comes back when its session opens.
nonisolated enum MachineStorageCard {
    static let cleanID = "clean"
    static let doneID = "done"
    static let identifier = "cmux.machineStorage.card"

    static func spec(_ state: MachineStorageState) -> CmuxDialogSpec {
        var lines: [String] = []
        if let disk = state.disk {
            lines.append(MachineStorageStrings.line(MachineStorageStrings.disk,
                                                    MachineStorageStrings.free(bytes(disk.available), of: bytes(disk.total))))
        }
        if let report = state.report {
            lines.append(MachineStorageStrings.line(MachineStorageStrings.reclaimable, bytes(report.reclaimable)))
            lines.append(MachineStorageStrings.line(MachineStorageStrings.kept, report.kept.formatted()))
            lines.append(MachineStorageStrings.line(MachineStorageStrings.toClean, report.toClean.formatted()))
        }
        let last = state.lastCleanup.map { $0.formatted(.relative(presentation: .named, unitsStyle: .wide)) }
        lines.append(MachineStorageStrings.line(MachineStorageStrings.lastCleanup, last ?? MachineStorageStrings.noCleanupYet))
        if let auto = (state.report?.autoCleanup) {
            lines.append(MachineStorageStrings.line(MachineStorageStrings.automatic, auto ? MachineStorageStrings.on : MachineStorageStrings.off))
        }
        var fields: [CmuxDialogField] = []
        switch state.phase {
        case .measuring: fields.append(.progress(MachineStorageStrings.measuring))
        case .cleaning: fields.append(.progress(MachineStorageStrings.cleaning))
        case .idle: break
        }
        if let freed = state.freed { fields.append(.note(MachineStorageStrings.freed(bytes(freed)), danger: false)) }
        fields.append(.note(MachineStorageStrings.safety, danger: false))
        let buttons = [
            CmuxDialogButton(id: doneID, title: MachineStorageStrings.done, role: .cancel),
            CmuxDialogButton(id: cleanID, title: MachineStorageStrings.cleanUpNow, role: .default, isEnabled: state.phase == .idle),
        ]
        return CmuxDialogSpec(usesTransientMaterial: true, title: MachineStorageStrings.title, lines: lines, fields: fields,
                              buttons: buttons, identifier: identifier, error: state.error)
    }

    /// Bytes as Finder writes a file size ("23.4 GB").
    static func bytes(_ count: UInt64) -> String {
        Int64(clamping: count).formatted(.byteCount(style: .file))
    }

    /// The home volume's size and what an app may still write there (display only, for a daemon
    /// whose report has no disk), read off the main thread.
    @concurrent static func homeVolume() async -> WorktreeCareReport.Disk? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let values = try? home.blockingResourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return WorktreeCareReport.Disk(total: UInt64(max(0, total)), available: UInt64(max(0, available)))
    }
}
