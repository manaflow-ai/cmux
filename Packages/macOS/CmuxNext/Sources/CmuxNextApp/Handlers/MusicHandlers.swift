import AppKit
import CmuxNextActions
import CmuxNextNowPlaying
import UniformTypeIdentifiers
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// cmux's own music player (cx-imt2i): Play Music… picks songs or folders (or plays its `url`, an
/// http(s) stream, else its `path`, a file or a folder) on the Now Playing card and the media keys;
/// Stop Music ends it. Streams take `url` because the CLI resolves a relative `path` against its
/// working directory, which turns a URL into a file path. A preview feature: without
/// `labs.previewFeatures` both are unavailable everywhere.
enum MusicHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let preview: @MainActor () -> String? = { [weak services] in
            services?.settings?.snapshot.previewFeatures == true ? nil : MusicStrings.preview
        }
        registry.bind("music.open", unavailable: preview, invoke: { [weak services, weak registry] invocation in
            guard let services, let registry else { return }
            let anchor = services.windows.active?.window
            let given = [invocation["url"], invocation["path"]].lazy.compactMap { $0?.stringValue.flatMap(url(for:)) }.first
            let work = services.work, priority = invocation.completionPriority
            // The pick (a sheet), then the folder walk on the files lane; the play or the refusal is one task on main.
            registry.trackWork(owner: "MusicHandlers.play", on: services.mainWork) { () -> [URL]? in
                var urls = given.map { [$0] }
                if urls == nil { urls = await choose(anchor: anchor) }
                guard let urls else { return nil }
                return try await work.run(priority, mayBlock: .files) { MusicPlayer.tracks(from: urls) }
            } then: { [weak services, weak registry] result in
                // A cancelled pick plays nothing and is not a failure.
                guard case .success(let picked) = result, let tracks = picked else { return nil }
                guard !tracks.isEmpty else {
                    registry?.refuse(MusicStrings.noSongs)
                    return ActionWorkFailure(MusicStrings.noSongs)
                }
                services?.cache.pageRequests.music.play(tracks)
                return nil
            }
        })
        registry.bind("music.stop", unavailable: preview, invoke: { [weak services, weak registry] _ in
            guard let music = services?.cache.pageRequests.music, music.nowPlaying != nil else {
                registry?.refuse(MusicStrings.nothingPlaying)
                return
            }
            music.stop()
        })
    }

    /// A stream URL as is, else a file path (with `~`); nil when blank, so a blank `url` falls back to `path`.
    private static func url(for path: String) -> URL? {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if let url = URL(string: path), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The songs and folders the person picks, nil on cancel.
    private static func choose(anchor: NSWindow?) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.message = MusicStrings.chooseMessage
        panel.prompt = MusicStrings.choosePrompt
        // A panel that drops its reply was cancelled.
        let response = (try? await withOnceContinuation { (continuation: OnceContinuation<NSApplication.ModalResponse, OnceContinuationError>) in
            if let anchor {
                panel.beginSheetModal(for: anchor) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }) ?? .cancel
        return response == .OK && !panel.urls.isEmpty ? panel.urls : nil
    }
}

enum MusicStrings {
    static var preview: String {
        String(localized: "music.refusal.preview", defaultValue: "The music player is a preview feature: turn on labs.previewFeatures in cmux.json.",
               table: "Music", bundle: .module)
    }

    static var noSongs: String {
        String(localized: "music.refusal.noSongs", defaultValue: "No songs there to play.", table: "Music", bundle: .module)
    }

    static var nothingPlaying: String {
        String(localized: "music.refusal.nothingPlaying", defaultValue: "No music is playing.", table: "Music", bundle: .module)
    }

    static var chooseMessage: String {
        String(localized: "music.choose.message", defaultValue: "Choose songs or folders to play.", table: "Music", bundle: .module)
    }

    static var choosePrompt: String {
        String(localized: "music.choose.prompt", defaultValue: "Play", table: "Music", bundle: .module)
    }
}
