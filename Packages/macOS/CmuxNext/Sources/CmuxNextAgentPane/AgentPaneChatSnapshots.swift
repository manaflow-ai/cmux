import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// What each agent chat's page last drew, as markup: the next document of that chat draws it in its
/// first frame, before its bundle runs, so a chat after a relaunch shows what it showed instead of
/// an empty pane and then a split reveal (Leo, 2026-11-07: "we need to make these after-restart
/// things load a lot faster"). The page writes it (`chat.snapshot.put`,
/// webviews/src/agent-session/acpmux/chatSnapshot), the page view's resources serve it to the next
/// document as `__snapshot/chat.js` (``AgentPageResources``), and the page draws and replaces it.
/// This is storage and serving only; the shape is the page's, kept opaque.
///
/// Kept as the chat tails are, beside them (``AgentPaneTailCache``): a disk of its own,
/// `agent-chat-snapshots` next to `agent-chat-tails`, at most ``chats`` files of ``bytes`` each,
/// saved and read off the main thread, owned by the app's state files so a quit awaits the saves.
/// Sign-out clears it with the tails; a chat the page forgets (purged, an attach that failed) is
/// forgotten here too; an incognito chat's page is never kept (``AgentPageProvider``).
/// The app has one, the chat tails' (``AgentPaneTailCache/snapshots``), whose lifecycle it shares.
@MainActor
public final class AgentPaneChatSnapshots {
    /// Chats whose copy is kept, as many as their tails.
    public nonisolated static let chats = AgentPaneTailCache.chats
    /// Most bytes one copy may take as UTF-8 JSON: four times the page's own 256 KiB bound
    /// (chatSnapshot/shared.ts), for the reason ``AgentPaneTailCache/bytes`` gives.
    public nonisolated static let bytes = 1024 * 1024
    /// The page's global the served script sets (chatSnapshot/shared.ts `SNAPSHOT_GLOBAL`).
    nonisolated static let global = "__cmuxChatSnapshot"
    /// The page's global for the theme key it gets now (chatSnapshot/shared.ts `SNAPSHOT_THEME_GLOBAL`).
    nonisolated static let themeGlobal = "__cmuxChatSnapshotTheme"
    /// The dynamic prefix the document loads it from.
    nonisolated static let prefix = "__snapshot"

    /// The disk; nil keeps nothing (a test host, the gallery). Unless set, the folder beside the
    /// tails', made on first use once the app made its state store.
    public var disk: AgentPaneTailDisk? {
        get {
            if let configuredDisk { return configuredDisk }
            guard let anchors = AgentPaneScrollAnchors.shared else { return nil }
            let disk = anchors.file.map { file in
                anchors.files.tails(in: file.deletingLastPathComponent().appending(path: "agent-chat-snapshots")) {
                    AgentPaneTailDisk(directory: $0, files: Self.chats, bytes: Self.bytes, qos: .userInitiated, accepts: { AgentPaneChatSnapshots.holds($0) })
                }
            }
            configuredDisk = .some(disk)
            return disk
        }
        set { configuredDisk = .some(newValue) }
    }
    private var configuredDisk: AgentPaneTailDisk??

    init() {}

    /// Whether `snapshot` is a page copy this keeps: an object with its markup, or the page's reason it
    /// wrote none (`miss`, served as why nothing drew). Its size is the disk's bound.
    nonisolated static func holds(_ snapshot: JSONValue) -> Bool {
        guard case .object(let fields) = snapshot else { return false }
        if case .string(let miss)? = fields["miss"], fields["html"] == nil { return !miss.isEmpty }
        guard case .string(let html)? = fields["html"], !html.isEmpty, case .number? = fields["v"] else { return false }
        return true
    }

    /// Whether `kept` is a copy the page draws (not only the reason it wrote none).
    nonisolated static func draws(_ kept: JSONValue) -> Bool {
        if case .object(let fields) = kept, case .string? = fields["html"] { true } else { false }
    }

    /// Keeps `snapshot` for chat `sessionId`; nil, or one this does not hold, forgets the one kept.
    public func remember(_ snapshot: JSONValue?, for sessionId: String) {
        guard AgentPaneTailCache.shared.acceptsTails else { return }
        let held: JSONValue? = if let snapshot, Self.holds(snapshot) { snapshot } else { nil }
        disk?.write(held, for: sessionId)
    }

    /// The copy kept for `sessionId`, read off the main thread; nil when none is, or the lifecycle
    /// changed while it read (sign-out).
    public func snapshot(for sessionId: String) async -> JSONValue? {
        let cache = AgentPaneTailCache.shared
        guard let disk, cache.acceptsTails else { return nil }
        let generation = cache.generation
        let read = await disk.read(sessionId)
        guard generation == cache.generation, cache.acceptsTails else { return nil }
        return read
    }

    /// Forgets every copy (sign-out, with the tails).
    func clear() {
        newest.removeAll()
        disk?.clear()
    }

    /// The `savedAt` of the newest copy kept per chat this launch: two pages can show one chat, and a
    /// copy one of them captured before the other's is never kept over it, whichever arrives last.
    /// One number per chat written to this launch.
    private var newest: [String: Double] = [:]

    /// The ops the page sends: `chat.snapshot.put {sessionId, html, ...}` (no `html` forgets it) and
    /// `chat.snapshot.get {sessionId}`, which answers the kept copy or null.
    nonisolated static func handles(method: String) -> Bool {
        method == "chat.snapshot.put" || method == "chat.snapshot.get"
    }

    /// Answers one op. `allowed` is false for an incognito chat (nothing kept, nothing read), and a
    /// page from before a sign-out (`pageGeneration`) writes nothing.
    func reply(_ method: String, params: JSONValue, op: String, allowed: Bool, pageGeneration: UInt64) async throws -> JSONValue {
        guard case .object(var body) = params, case .string(let session)? = body["sessionId"], !session.isEmpty
        else { throw PageError.invalidParams(op) }
        if method == "chat.snapshot.get" {
            guard allowed, let kept = await snapshot(for: session), Self.draws(kept) else { return .null }
            return kept
        }
        // A put answers `{kept}`: whether this keeps it (the page's own record of its writes).
        guard allowed, pageGeneration == AgentPaneTailCache.shared.generation, AgentPaneTailCache.shared.acceptsTails
        else { return ["kept": .bool(false)] }
        body["sessionId"] = nil
        // A copy captured before the one kept (another page of the same chat wrote since) is dropped.
        if case .number(let savedAt)? = body["savedAt"] {
            if let kept = newest[session], savedAt < kept { return ["kept": .bool(false)] }
            newest[session] = savedAt
        }
        // Typed: an untyped `nil` could read as `JSONValue.null` (ExpressibleByNilLiteral). With no
        // markup, the page's reason (`miss`) is kept in its place, for the next document's record.
        let kept: JSONValue? = if case .string? = body["html"] {
            .object(body)
        } else if case .string(let miss)? = body["miss"], !miss.isEmpty {
            .object(["miss": .string(String(miss.prefix(200)))])
        } else {
            .none
        }
        remember(kept, for: session)
        return ["kept": .bool(kept.map(Self.draws) == true && disk != nil)]
    }

    /// The script the document loads (async) beside its bundle: sets the page's global to chat
    /// `sessionId`'s copy, or to null when there is none (or no chat, or it may not be kept), then
    /// calls the page's boot, which draws it (chatSnapshot/boot.ts). `read` is that chat's copy
    /// already being read (``AgentPageResources``), so the answer waits on no second read.
    func script(for sessionId: String?, allowed: Bool, themeKey: String? = nil, read: Task<JSONValue?, Never>? = nil) async -> Data {
        var kept: JSONValue?
        if allowed, let sessionId, !sessionId.isEmpty {
            let cache = AgentPaneTailCache.shared
            let generation = cache.generation
            if let read { kept = await read.value } else { kept = await snapshot(for: sessionId) }
            // A sign-out while it read: what was read is no one's to serve.
            if generation != cache.generation || !cache.acceptsTails { kept = nil }
        }
        return script(for: sessionId, allowed: allowed, themeKey: themeKey, kept: kept)
    }

    /// ``script(for:allowed:themeKey:read:)`` once the chat's copy is read: `kept` is what the store
    /// holds for it, nil for none.
    func script(for sessionId: String?, allowed: Bool, themeKey: String?, kept: JSONValue?) -> Data {
        var text = "self.\(Self.global)="
        // Why there is none, for the page's own record (chatSnapshot/live.ts `chatSnapshotReport`).
        var why = "kept"
        if !allowed {
            why = "not-kept-here"
        } else if sessionId?.isEmpty ?? true {
            why = "no-chat"
        }
        if why == "kept", let kept, Self.draws(kept) {
            kept.appendCompactText(to: &text)
        } else {
            if why == "kept" { why = disk == nil ? "no-store" : kept?["miss"]?.stringValue.map { "none: \($0)" } ?? "none" }
            text += "null"
        }
        text += ";self.\(Self.global)Why="
        JSONValue.string(why).appendCompactText(to: &text)
        // The theme the page gets now: a copy drawn under another one is not drawn.
        text += ";self.\(Self.themeGlobal)="
        JSONValue.string(themeKey ?? "").appendCompactText(to: &text)
        // The page's boot (chatSnapshot/shared.ts `SNAPSHOT_BOOT_GLOBAL`), absent until it ran: it
        // then reads the globals itself.
        text += ";self.\(Self.global)Boot?.();"
        return Data(text.utf8)
    }
}
