import AppKit
import CmuxNextDesign

/// The message box's file picker: the app's panel made ahead of the click
/// (`MadeAheadOpenPanel`, shared with an agent composer's attach), so the "+"
/// pays only the sheet. Home warms it when its transcript reaches a window.
@MainActor
enum HomeAttachmentPanel {
    private static var shared: MadeAheadOpenPanel { .shared }
    /// Whether the panel was made ahead of a click.
    static var isMade: Bool { shared.isMade }
    /// The warm-up checks run so far, and whether another is pending.
    static var warmChecks: Int { shared.warmChecks }
    static var isWarming: Bool { shared.isWarming }

    /// A configured panel: the one made ahead when it is free, else a new one
    /// (it shows on another window). Nil when the new one came back dead (no GUI session).
    static func panel() -> NSOpenPanel? {
        guard let panel = shared.panel() else { return nil }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = HomeStrings.attachPrompt
        panel.allowedContentTypes = HomeComposerCheck.pickerTypes
        return panel
    }

    /// Opens the picker as a sheet on `window` at once (no task hop). A window
    /// that already shows a sheet (the picker, a second click) opens none. A dead
    /// panel shows no sheet and ends at once as a cancel (`done(nil)`).
    static func present(for window: NSWindow, done: @escaping (_ urls: [URL]?) -> Void) {
        guard window.attachedSheet == nil else { return }
        guard let panel = panel() else {
            done(nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            done(response == .OK ? panel.urls : nil)
        }
    }

    /// Makes the panel once the person has paused (`MadeAheadOpenPanel.warmWhenIdle`).
    static func warmWhenIdle() { shared.warmWhenIdle() }
}
