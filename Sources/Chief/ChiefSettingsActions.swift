import AppKit
import CmuxChief
import CmuxHomeCore
import Foundation

/// What the Chief Settings panel reads and changes beyond the engine
/// settings: Chief's name, the last turn's stats and the transcript log.
extension ChiefService {
    /// Saves Chief's name in the profile and renames every Chief participant
    /// (the header pill, list rows and transcript read the participant's
    /// name; the sidebar's Home row reads ``ChiefProfile/currentName()``).
    ///
    /// - Parameter name: The new name; nil or blank goes back to "Chief".
    func setChiefName(_ name: String?) {
        guard let home else { return }
        var profile = ChiefProfile.load(from: home)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        profile.name = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        try? profile.save(to: home)
        NotificationCenter.default.post(name: ChiefProfile.didChange, object: nil)
        guard let owner else { return }
        let display = profile.displayName
        // task-owner: one rename on the owner's actor; ends with it
        Task { _ = try? await owner.renameChiefs(to: display) }
    }

    /// The last finished turn of `conversation` in this session.
    func lastTurnStats(in conversation: ConversationID) async -> ChiefTurnStats? {
        guard let owner else { return nil }
        return await owner.lastTurnStats(in: conversation)
    }

    /// Reveals `conversation`'s JSON Lines log in Finder (its folder when the file is not written yet).
    func revealTranscriptLog(_ conversation: ConversationID) {
        guard let owner else { return }
        let file = owner.logFile(for: conversation)
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file.deletingLastPathComponent()])
        }
    }

    /// The Chief home's path for display, `~` for the user's home (the Show in Finder link's tooltip).
    var homeDisplayPath: String? {
        home.map { ($0.root.path as NSString).abbreviatingWithTildeInPath }
    }

    /// Shows the Chief home folder in Finder.
    func revealHome() {
        guard let home else { return }
        NSWorkspace.shared.activateFileViewerSelecting([home.root])
    }
}
