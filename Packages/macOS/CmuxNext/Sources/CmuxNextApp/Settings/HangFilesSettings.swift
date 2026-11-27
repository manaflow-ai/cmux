import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings

/// Debug Settings > Hangs: the toggle for the main-thread watchdog's hang files
/// (``HangEpisodeRecorder``) and the list of recent ones on the Debug Settings page. English
/// developer text, as every Debug Settings section (plans/cmux-next/debug-settings.md).
enum HangFileTunables {
    nonisolated static let section = TunableSection(id: "hangs", title: "Hangs", symbol: "exclamationmark.triangle", order: 100)

    /// On (the default): a main thread blocked for 2 s writes its stack to
    /// `~/Library/Logs/<bundle id>/hangs`, one file per hang. Release and RC never activate the
    /// tunable store, so they keep it on too.
    nonisolated static let enabled = Tunable<Bool>.toggle(
        "diagnostics.hangFiles", section, "Write a file for each main-thread hang",
        help: "When the main thread is blocked for 2 seconds, the watchdog writes its stack to ~/Library/Logs/<bundle id>/hangs (the newest 20 files are kept) and finishes the file with the duration once the app answers again. The list below shows them.",
        default: true, code: "HangFileTunables.enabled")

    static var all: [TunableDescriptor] { [enabled.descriptor] }

    /// The recorder the watchdog writes through, in this app's log folder.
    static func recorder(bundleID: String?) -> HangEpisodeRecorder {
        HangEpisodeRecorder(directory: HangEpisodeRecorder.defaultDirectory(bundleID: bundleID),
                            isEnabled: { enabled.value })
    }

    /// The page's `hangs` object: the card's text and the recent hangs, newest first. A lock
    /// and at most 20 entries; no file is read.
    static func pageJSON(_ recorder: HangEpisodeRecorder?) -> JSONValue {
        let items: [JSONValue] = (recorder?.entries ?? []).map { entry in
            let seconds = String(format: "%.1f s", entry.duration / .seconds(1))
            return [
                "path": .string(entry.url.path),
                "started_text": .string(entry.started.formatted(date: .abbreviated, time: .standard)),
                "duration_text": .string(entry.ongoing ? "at least \(seconds), still blocked when written" : seconds),
                "ongoing": .bool(entry.ongoing),
                "frames": .array(entry.topFrames.map { JSONValue.string($0) }),
            ]
        }
        return [
            "section": .string(section.id), "title": "Recent hangs",
            "folder": .string(recorder.map { ($0.directory.path as NSString).abbreviatingWithTildeInPath } ?? ""),
            "empty": "No main-thread hangs recorded.", "show_folder": "Show Folder",
            "reveal": "Show in Finder", "copy": "Copy", "items": .array(items),
        ]
    }

    /// `cmux.debug.tunables.hangs.reveal {path?}`: the file (one of the listed ones), else the folder.
    @MainActor
    static func reveal(_ recorder: HangEpisodeRecorder?, path: String?) throws {
        guard let recorder else { throw PageError.invalidParams("hang files are off in this build") }
        guard let path else { return NSWorkspace.shared.revealInBackground([recorder.directory]) }
        // A listed file that is still a regular file in the hang folder (one lstat; never a symlink's target).
        guard let entry = recorder.entries.first(where: { $0.url.path == path }), recorder.isHangFile(entry.url) else {
            throw PageError.invalidParams("not a listed hang file")
        }
        NSWorkspace.shared.revealInBackground([entry.url])
    }

    /// `cmux.debug.tunables.hangs.copy {path}`: the file's text (`{text}`); the page copies it.
    static func text(_ recorder: HangEpisodeRecorder?, path: String?) async throws -> JSONValue {
        guard let recorder, let path, let entry = recorder.entries.first(where: { $0.url.path == path }) else {
            throw PageError.invalidParams("not a listed hang file")
        }
        // task-owner: one bounded file read (at most 64 KB) off the main actor, awaited here.
        let text = await Task.detached(priority: .userInitiated) { recorder.text(of: entry.url) }.value
        guard let text else { throw PageError.invalidParams("the hang file is gone") }
        return ["text": .string(text)]
    }
}
