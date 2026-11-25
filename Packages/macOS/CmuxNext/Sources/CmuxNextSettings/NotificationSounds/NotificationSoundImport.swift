import AppKit
public import CmuxNextActions
public import Foundation
import UniformTypeIdentifiers

/// Import Sound… and the Settings page's Custom Sound…: the person picks an audio file (or the CLI
/// names one), cmux copies it into its own sounds folder (``NotificationSoundLibrary``), lists the
/// sounds again and hands the new file to the player, and returns the name cmux.json stores. The
/// Settings page also previews through it.
@MainActor
public struct NotificationSoundImport {
    private let host: any NotificationSoundHost
    private let gate: NotificationSoundGate

    /// - Parameters:
    ///   - host: The open panel's window and the disk lanes.
    ///   - gate: Its library takes the copy; its player plays it.
    public init(host: any NotificationSoundHost, gate: NotificationSoundGate) {
        self.host = host
        self.gate = gate
    }

    /// Imports `file`, or the file the person picks.
    ///
    /// - Returns: The sound's name, nil when the person cancelled, or the failure they read.
    public func run(_ file: URL?) async -> Result<String?, ActionWorkFailure> {
        var picked = file
        if picked == nil { picked = await choose() }
        guard let url = picked else { return .success(nil) }
        let library = gate.library
        do {
            let name = try await host.soundWork.run(.userBlocking, mayBlock: .files) { try library.importSound(from: url) }
            await gate.refreshSounds(work: host.soundWork)
            return .success(name)
        } catch let refusal as NotificationSoundLibrary.ImportRefusal {
            return .failure(ActionWorkFailure(refusal.message))
        } catch {
            return .failure(ActionWorkFailure(NotificationSoundStrings.importFailed(url.lastPathComponent)))
        }
    }

    /// The Settings page's ▷: `name` at the person's volume and Sound Duration.
    public func preview(_ name: String) {
        gate.preview(name, volume: gate.volume)
    }

    /// The Settings page's Custom Sound…: the picked file's sound name, nil when the person left
    /// the panel.
    ///
    /// - Throws: ``ActionWorkFailure`` with what the person reads.
    public func pick() async throws(ActionWorkFailure) -> String? {
        try await run(nil).get()
    }

    /// The sound file the person picks, nil on cancel.
    private func choose() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.message = NotificationSoundStrings.chooseMessage
        panel.prompt = NotificationSoundStrings.choosePrompt
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let anchor = host.soundAnchorWindow {
                panel.beginSheetModal(for: anchor) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }
}
