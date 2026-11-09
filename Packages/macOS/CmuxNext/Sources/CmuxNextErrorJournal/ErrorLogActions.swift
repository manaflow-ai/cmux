public import CmuxNextActions
public import Foundation

/// Help's log actions, one path for the menu, the menu bar menu and the palette (the App binds them
/// once): Reveal Logs in Finder, Copy Logs (the build, the system and the journal's problems of the
/// last 3 days, as text: ``ErrorJournalReport``) and Clear Error Log (empties the journal, as
/// `cmux errors clear`, so Copy Logs after a repro holds only what the repro logged).
@MainActor
public struct ErrorLogActions {
    private let journal: @MainActor () -> (journal: ErrorJournal, sources: [any ErrorHarvestSource])?
    private let directory: @MainActor () -> URL
    private let copy: @MainActor (String) -> Void
    private let reveal: @MainActor (URL) -> Void

    /// - Parameters:
    ///   - journal: This build's journal and the logs a Copy Logs harvests first, read at each run; nil
    ///     while it has not started (Copy Logs then copies the header alone).
    ///   - directory: The journal's folder, every log it harvests.
    ///   - copy: Puts text on the clipboard.
    ///   - reveal: Shows a folder in Finder.
    public init(journal: @escaping @MainActor () -> (journal: ErrorJournal, sources: [any ErrorHarvestSource])?,
                directory: @escaping @MainActor () -> URL,
                copy: @escaping @MainActor (String) -> Void, reveal: @escaping @MainActor (URL) -> Void) {
        self.journal = journal
        self.directory = directory
        self.copy = copy
        self.reveal = reveal
    }

    /// Binds `help.revealLogs`, `help.copyLogs` and `help.clearErrorLog`.
    public func bind(into registry: ActionRegistry) {
        registry.bindEffect("help.revealLogs", effect: { [reveal, directory] _ in
            reveal(directory())
            return .done
        })
        registry.bindEffect("help.copyLogs", effect: { [journal, directory, copy] _ in
            let info = Bundle.main.infoDictionary ?? [:]
            let header = [
                "cmux \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) \(Bundle.main.bundleIdentifier ?? "?")",
                "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                "Logs: \(directory().path)",
            ]
            guard let found = journal() else {
                copy(ErrorJournalReport(header: header, entries: []).text())
                return .done
            }
            // action-wait-allow: the text exists only after the journal reads the logs and its entries off the main actor
            return .waiting(.fileSystem) {
                _ = await found.journal.harvest(found.sources)
                let entries = await found.journal.entries(ErrorQuery(since: Date().addingTimeInterval(-3 * 86_400), limit: 200))
                copy(ErrorJournalReport(header: header, entries: entries).text())
                return nil
            }
        })
        registry.bindEffect("help.clearErrorLog", effect: { [journal] _ in
            guard let journal = journal()?.journal else { return .done }
            // action-wait-allow: the journal is an actor that rewrites its file off the main actor
            return .waiting(.fileSystem) {
                await journal.clear()
                return await journal.writeError.map { ActionWorkFailure(refusal: .unavailable, reason: $0) }
            }
        })
    }
}
