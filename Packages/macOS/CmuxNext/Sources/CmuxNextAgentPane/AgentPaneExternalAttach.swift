public import AppKit
import CmuxNextCompat
public import CmuxNextControl
public import CmuxNextSettings
public import Foundation
import os
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
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.external-attach")
    /// The chat that last took files: `chat.composer.get` reads it back.
    private weak var last: AgentPaneView?
    /// When ``last`` took its files (wall clock): `chat.composer.get`'s `attached_at_ms`, so a probe
    /// times a door from the app's own stamp rather than from how often it reads the composer.
    private var lastAttachedAt: Date?
    /// Files waiting for the new chat opened for them: more that come meanwhile join them, rather
    /// than open a second chat. One older than ``openingLimit`` is a chat that never came. `attempt`
    /// names the chat opened for them.
    private var opening: (urls: [URL], claimed: String?, since: ContinuousClock.Instant, attempt: Int)?
    /// Files whose chat never came or was not made: they go with the next files, never dropped.
    private var stranded: (urls: [URL], claimed: String?)?
    private var attempts = 0
    public nonisolated static let openingLimit: Duration = .seconds(10)
    private let now: () -> ContinuousClock.Instant

    public init() { now = { .now } }

    /// A test's clock, for files that waited past ``openingLimit``.
    init(now: @escaping () -> ContinuousClock.Instant) { self.now = now }

    /// Puts `urls` into `target`'s composer, or, with no target, a new chat's: `openChat` opens one
    /// and calls back with its page once it is made (nil when it is not), answering false when it
    /// could not start one. `show` brings a chat's tab forward. `claimed`: the bundle id of the app
    /// the files came from, when known. Files an earlier chat never took go with these.
    public func attach(_ urls: [URL], claimed: String?, target: AgentPaneView?,
                       openChat: (@escaping @MainActor (AgentPaneView?) -> Void) -> Bool,
                       show: @escaping @MainActor (AgentPaneView) -> Void) {
        guard !urls.isEmpty else { return }
        if let waiting = opening {
            if now() - waiting.since < Self.openingLimit {
                opening = (waiting.urls + urls, waiting.claimed ?? claimed, waiting.since, waiting.attempt)
                return
            }
            Self.logger.error("external attach: no chat came within \(Self.openingLimit, privacy: .public) for \(waiting.urls.count, privacy: .public) file(s); they go with the next")
            strand(waiting.urls, claimed: waiting.claimed)
            opening = nil
        }
        let kept = stranded
        stranded = nil
        let urls = (kept?.urls ?? []) + urls, claimed = kept?.claimed ?? claimed
        if let target { return deliver(urls, claimed: claimed, to: target, show: show) }
        attempts += 1
        let attempt = attempts
        opening = (urls, claimed, now(), attempt)
        let started = openChat { [weak self] view in
            // A chat opened for files that have since gone with a later chat takes none.
            guard let self, let waiting = opening, waiting.attempt == attempt else { return }
            opening = nil
            guard let view else {
                Self.logger.error("external attach: the new chat was not made; \(waiting.urls.count, privacy: .public) file(s) go with the next")
                return strand(waiting.urls, claimed: waiting.claimed)
            }
            deliver(waiting.urls, claimed: waiting.claimed, to: view, show: show)
        }
        if !started, opening?.attempt == attempt {
            opening = nil
            Self.logger.error("external attach: no chat could open; \(urls.count, privacy: .public) file(s) go with the next")
            strand(urls, claimed: claimed)
        }
    }

    private func strand(_ urls: [URL], claimed: String?) {
        stranded = ((stranded?.urls ?? []) + urls, stranded?.claimed ?? claimed)
    }

    /// Whether files wait for a new chat (``attach(_:claimed:target:openChat:show:)``).
    var waitsForChat: Bool { opening != nil }

    /// The session of the chat that last took files, while no new chat is still opening for more:
    /// nil for a chat not started yet (`chat.capture.toChat`'s `session`).
    public var lastSession: String? {
        guard opening == nil else { return nil }
        return last?.model.sessionId
    }

    /// The files waiting for a chat (one opening, or the next files'), oldest first.
    var waitingFiles: [URL] { (stranded?.urls ?? []) + (opening?.urls ?? []) }

    private func deliver(_ urls: [URL], claimed: String?, to view: AgentPaneView, show: @MainActor (AgentPaneView) -> Void) {
        last = view
        lastAttachedAt = Date()
        show(view)
        view.attachExternal(urls, claimed: claimed)
        view.focusComposer()
    }

    /// `chat.composer.get`: what the composer holds of the chat that last took files from another
    /// app, else of `focused`: `{session, attachments: [{name, mimeType, bytes, source}], text}`,
    /// `session` null for a chat not started yet, and all empty without a chat. The chat that last
    /// took files also answers `attached_at_ms`: the Unix ms its composer took them.
    public func composerState(focused: AgentPaneView?) async -> JSONValue {
        if let last { return Self.stamped(await last.composerReadback(), attachedAt: lastAttachedAt) }
        guard let focused else { return Self.noComposer }
        return await focused.composerReadback()
    }

    /// `state` with `attached_at_ms` (Unix ms of `attachedAt`) added, unchanged without a stamp or an object.
    public nonisolated static func stamped(_ state: JSONValue, attachedAt: Date?) -> JSONValue {
        guard let attachedAt, case .object(var fields) = state else { return state }
        fields["attached_at_ms"] = .number((attachedAt.timeIntervalSince1970 * 1000).rounded())
        return .object(fields)
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
