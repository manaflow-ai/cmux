public import AppKit
import CmuxNextCompat
public import CmuxNextControl
public import CmuxNextSettings
public import Foundation
import UniformTypeIdentifiers

/// The one route that puts files from another app into an agent chat's composer as an unsent draft
/// (Leo, 2026-11-08, ask-a862e90c70: "holy f***. those NEED to be written down and FIXED and
/// IMPROVED", on a screenshot that could not reach a chat from another app). Its doors: an image
/// opened with cmux or dropped on its Dock icon, the Send to cmux Chat service, and later a capture
/// shortcut and the Share menu; the App's `ExternalOpenController.attachToChat(_:from:)` brings them
/// all here, with the chat that takes them.
///
/// The files go to the chat the App names (the window's focused agent chat, else the one focused most
/// recently there), else a new agent chat it opens; that chat's tab comes forward and its composer
/// takes the keyboard. `chat.composer.get` reads back what the composer of the chat that last took
/// files holds.
@MainActor
public final class AgentPaneExternalAttach {
    /// The chat that last took files: `chat.composer.get` reads it back.
    private weak var last: AgentPaneView?
    /// Files waiting for the new chat opened for them: more that come meanwhile join them, rather
    /// than open a second chat. One older than ``openingLimit`` is a chat that never came.
    private var opening: (urls: [URL], claimed: String?, since: ContinuousClock.Instant)?
    public nonisolated static let openingLimit: Duration = .seconds(10)

    public init() {}

    /// Puts `urls` into `target`'s composer, or, with no target, a new chat's: `openChat` opens one
    /// and calls back with its page once it is made (nil when it is not), answering false when it
    /// could not start one. `show` brings a chat's tab forward. `claimed`: the bundle id of the app
    /// the files came from, when known.
    public func attach(_ urls: [URL], claimed: String?, target: AgentPaneView?,
                       openChat: (@escaping @MainActor (AgentPaneView?) -> Void) -> Bool,
                       show: @escaping @MainActor (AgentPaneView) -> Void) {
        guard !urls.isEmpty else { return }
        if let waiting = opening, ContinuousClock.now - waiting.since < Self.openingLimit {
            opening = (waiting.urls + urls, waiting.claimed ?? claimed, waiting.since)
            return
        }
        opening = nil
        if let target { return deliver(urls, claimed: claimed, to: target, show: show) }
        opening = (urls, claimed, .now)
        let started = openChat { [weak self] view in
            guard let self, let waiting = opening else { return }
            opening = nil
            if let view { deliver(waiting.urls, claimed: waiting.claimed, to: view, show: show) }
        }
        if !started { opening = nil }
    }

    /// Whether files wait for a new chat (``attach(_:claimed:target:openChat:show:)``).
    var waitsForChat: Bool { opening != nil }

    private func deliver(_ urls: [URL], claimed: String?, to view: AgentPaneView, show: @MainActor (AgentPaneView) -> Void) {
        last = view
        show(view)
        view.attachExternal(urls, claimed: claimed)
        view.focusComposer()
    }

    /// `chat.composer.get`: what the composer holds of the chat that last took files from another
    /// app, else of `focused`: `{session, attachments: [{name, mimeType, bytes, source}], text}`,
    /// `session` null for a chat not started yet, and all empty without a chat.
    public func composerState(focused: AgentPaneView?) async -> JSONValue {
        guard let view = last ?? focused else { return Self.noComposer }
        return await view.composerReadback()
    }

    public nonisolated static let noComposer: JSONValue = .object(["session": .null, "attachments": .array([]), "text": .string("")])

    /// The control method (`cmux app call chat.composer.get '{}'`), for tests and probes. `focused`:
    /// the window's focused agent chat.
    public func controlMethods(focused: @escaping @MainActor () -> AgentPaneView?) -> [ControlMethod] {
        [.async("chat.composer.get") { [weak self] _ in
            await self?.composerState(focused: focused()) ?? Self.noComposer
        }]
    }
}

extension AgentPaneDroppedPaths {
    /// Whether a file of extension `ext` is a picture (PNG, JPEG, HEIC, TIFF, GIF and the rest).
    public nonisolated static func isImage(_ ext: String) -> Bool {
        !ext.isEmpty && UTType(filenameExtension: ext.lowercased())?.conforms(to: .image) == true
    }

    /// Send to cmux Chat's pictures: the image files among `paths` (what Finder selected), else none.
    public nonisolated static func imageFiles(_ paths: [String]) -> [URL] {
        paths.map { URL(fileURLWithPath: $0) }.filter { isImage($0.pathExtension) }
    }

    /// A picture's bytes on `pasteboard` (another app's selection) and the extension its file takes:
    /// PNG first, else TIFF (the page converts TIFF as it does a pasted one).
    public static func imageData(on pasteboard: NSPasteboard) -> (data: Data, ext: String)? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty { return (png, "png") }
        if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty { return (tiff, "tiff") }
        return nil
    }

    /// Keeps a picture's bytes as `Image.<ext>` in a fresh folder under Chat Uploads (``ChatUploadFolders``,
    /// whose expiry covers it), off the main actor; nil when it can't be written.
    public nonisolated static func save(_ data: Data, ext: String, in folders: ChatUploadFolders) async -> URL? {
        let folder = folders.freshUpload(session: nil)
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let file = folder.appending(path: "Image.\(ext)")
            do {
                try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.blockingWrite(to: file, options: .atomic)
                return file
            } catch {
                return nil
            }
        }.value
    }
}
