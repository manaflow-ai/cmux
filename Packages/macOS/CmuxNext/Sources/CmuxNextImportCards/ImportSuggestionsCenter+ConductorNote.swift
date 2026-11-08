public import CmuxNextSidebar
import CmuxNextImportSuggestions
import Foundation

/// The sidebar's one-time Import from Conductor note, in the shared notice card: while this Mac
/// has Conductor, before Conductor Cloud shuts down, until the import starts or the person closes
/// it (``ImportSuggestionState/showsConductorNote(findings:jobs:now:)``). Its button opens
/// Settings › Import; its x closes it for good, kept with the cards' other state.
extension ImportSuggestionsCenter {
    public static let conductorNoteID = "conductor-import"
    static let conductorNoteOpen = "open-import"

    /// The note while it shows; nil otherwise, and while the cards are off.
    public var conductorNote: SidebarNoticeCard? {
        guard isEnabled, !conductorDeadlinePassed, state.showsConductorNote(findings: findings, jobs: ledger, now: now()) else { return nil }
        return SidebarNoticeCard(id: Self.conductorNoteID, symbol: "square.and.arrow.down", title: ConductorImportStrings.noteTitle,
                                 detail: ConductorImportStrings.noteDetail,
                                 actions: [SidebarNoticeCard.Action(id: Self.conductorNoteOpen, title: ConductorImportStrings.noteOpen, prominent: true)],
                                 dismissLabel: ConductorImportStrings.noteClose)
    }

    /// Wakes once at Conductor Cloud's shutdown (by the center's clock) so a note still on screen
    /// goes then: nothing else the note reads changes at that moment. One deadline, no polling.
    func scheduleConductorDeadline() {
        guard !conductorDeadline.isScheduled, !conductorDeadlinePassed else { return }
        let wait = ImportSuggestionState.conductorDeadline.timeIntervalSince(now())
        guard wait > 0 else {
            conductorDeadlinePassed = true
            return
        }
        conductorDeadline.schedule(after: .seconds(wait)) { @MainActor [weak self] in self?.conductorDeadlinePassed = true }
    }

    /// A press on notice `card`: the note's button opens Settings › Import, its x (`action` nil)
    /// closes it. False when `card` is another owner's.
    public func answerConductorNote(_ card: String, action: String?) -> Bool {
        guard card == Self.conductorNoteID else { return false }
        if let action {
            if action == Self.conductorNoteOpen { openSettings() }
        } else {
            closeConductorNote()
        }
        return true
    }
}
