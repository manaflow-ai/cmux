public import CmuxNextDaemon
import Foundation

/// The names of chats whose acpmux runs on another machine (cmux#55668). This Mac's watch never lists a Cloud
/// machine's chats, so a Cloud chat's tab read its workspace's `workspace-N` and the workspace never took the
/// chat's title. The chat's page reads its summary over its remote wire (`RemoteAcpmuxWire`, the attach and each
/// `_acpmux/session_changed`), and the app notes it here: the same name readers (``title(for:)``,
/// ``generatedTitle(for:)``, ``sessionName(for:)``, ``displayName(for:)``) then answer for it as for a local chat,
/// so the tab strip and workspace auto-naming take one path for both.
///
/// Records are keyed by host and session (session ids are each daemon's own) and hold names only: a remote
/// chat's turn state stays its machine's (``isWorking(_:isChatMachine:)`` reads the acpmux peers' rows).
///
/// Another machine's summary is untrusted input. Only the name fields are read (``remoteFields``; never its icon,
/// whose inline image bytes this Mac would decode), each capped before parsing, and every name kept is plain text
/// (``plainName(_:)``): one line, no control or invisible characters (bidi overrides, zero-width), at most
/// ``remoteNameLimit`` characters.
extension AgentTurnStateStore {
    /// The most remote chats whose names are kept; past it the host holding the most is dropped (a page notes its chat
    /// again on each attach and change).
    static let remoteLimit = 4096

    /// The key of `session` on `host` in ``remoteSessions``. A NUL never occurs in a session id, so it never
    /// collides with the ``awaited`` signal of a local session.
    static func remoteKey(host: String, session: String) -> String { host + "\u{0}" + session }
    /// The host of a ``remoteKey(host:session:)``.
    static func remoteHost(of key: String) -> String { String(key.prefix { $0 != "\u{0}" }) }

    /// The summary fields a remote chat's names are read from; any other is dropped.
    static let remoteFields = ["sessionId", "title", "titleSource", "lastPrompt", "name", "harness", "family", "displayName"]
    /// The most characters a field is read at, before parsing, and a kept name at.
    nonisolated static let remoteFieldLimit = 4096, remoteNameLimit = 200
    /// The most former names kept (acpmux keeps a few; the newest are the ones a workspace name matches).
    static let remoteFormerNamesKept = 8

    /// The name fields of `summary`, each capped (``remoteFieldLimit``); never its icon or anything else.
    static func remoteSummary(_ summary: [String: Any]) -> [String: Any] {
        var safe: [String: Any] = [:]
        for key in remoteFields {
            if let text = summary[key] as? String { safe[key] = capped(text) }
        }
        if let former = summary["formerNames"] as? [Any] {
            safe["formerNames"] = former.suffix(remoteFormerNamesKept).compactMap { ($0 as? String).map(capped) }
        }
        return safe
    }

    /// `text` cut to ``remoteFieldLimit`` Unicode scalars: a cap by `Character` lets one grapheme stack any number of
    /// combining marks past it.
    nonisolated static func capped(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(remoteFieldLimit)))
    }

    /// Whether `host` reads as a machine's host (`install:` or `registry:` and a short id without control characters);
    /// a remote's word is noted under nothing else.
    nonisolated static func isRemoteHost(_ host: String) -> Bool {
        guard host.hasPrefix("install:") || host.hasPrefix("registry:"), host.utf8.count <= 266 else { return false }
        return !host.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
    }

    /// The most combining marks kept on one character (a stack of them overflows the tab strip and the row).
    nonisolated static let remoteMarksPerCharacter = 2

    /// `text` as plain one-line text: line breaks, tabs and control characters become one space; invisible characters
    /// (bidi overrides and isolates, zero-width spaces, Hangul fillers, the blank braille cell, every default-ignorable
    /// code point but the emoji presentation selector and the joiner between two emoji) are dropped; at most
    /// ``remoteMarksPerCharacter`` combining marks stay on a character. Trimmed and capped at ``remoteNameLimit``
    /// characters; nil when nothing readable is left.
    public nonisolated static func plainName(_ text: String?) -> String? {
        guard let text else { return nil }
        let input = Array(text.unicodeScalars.prefix(remoteFieldLimit))
        func emoji(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return (scalar.properties.isEmoji && scalar.value > 0x7F) || scalar == "\u{FE0F}" || scalar.properties.isEmojiModifier
        }
        var scalars = String.UnicodeScalarView()
        var spaced = true, marks = 0
        for (index, scalar) in input.enumerated() {
            let category = scalar.properties.generalCategory
            switch category {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                if !spaced { scalars.append(" ") }
                spaced = true
                marks = 0
                continue
            case .format, .surrogate, .privateUse, .unassigned:
                // The joiner of an emoji sequence (👩‍💻) stays; any other format character never shows.
                guard scalar == "\u{200D}", emoji(scalars.last), emoji(input.dropFirst(index + 1).first) else { continue }
            case .nonspacingMark, .enclosingMark, .spacingMark:
                if scalar == "\u{FE0F}" || scalar == "\u{FE0E}" || scalar == "\u{20E3}" { break }
                guard !scalar.properties.isDefaultIgnorableCodePoint, !spaced, marks < remoteMarksPerCharacter else { continue }
                marks += 1
            default:
                guard !scalar.properties.isDefaultIgnorableCodePoint, scalar != "\u{2800}" else { continue }
                marks = 0
            }
            scalars.append(scalar)
            spaced = false
        }
        let plain = String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(remoteNameLimit))
        return plain.isEmpty ? nil : plain
    }

    /// Whether `session` is a session id this Mac keys a remote record by: short, with no control character.
    static func isRemoteSessionID(_ session: String) -> Bool {
        !session.isEmpty && session.utf8.count <= 256 && !session.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// How many remote chats have names noted (tests).
    public var remoteRecordCount: Int { remoteSessions.count }

    /// The most chats of one host whose names are kept: past it, only that host's start again, never another machine's.
    static let remoteLimitPerHost = 512
    /// What ``remoteHostMachines`` holds for a host two machines claimed.
    static let contestedRemoteHost = ""

    /// Notes the names of the chat `summary` describes (an acpmux session summary) on host `host` (the tab's
    /// `install:<id>`, ``AgentSessionRef/host``), read from `machine` (this Mac's id of the daemon whose wire read it, never
    /// the remote's word). Refused before this Mac knows its own host, for this Mac's host and the mirrored ones (their watch
    /// owns those records), and for a host another machine noted first: a machine can name only its own chats, and a host
    /// two machines claim is noted from neither again, its names dropped. Writes only what changed.
    public func noteRemote(_ untrusted: [String: Any], host: String, machine: String) {
        let summary = Self.remoteSummary(untrusted)
        guard let localHost, let session = summary["sessionId"] as? String, Self.isRemoteSessionID(session), Self.isRemoteHost(host),
              !machine.isEmpty, host != localHost, !mirroredHosts.contains(host) else { return }
        switch remoteHostMachines[host] {
        case machine?: break
        case nil:
            // Bounded: past the limit, hosts holding no names are forgotten (a contested one stays contested).
            if remoteHostMachines.count >= Self.remoteLimit {
                let held = Set(remoteSessions.keys.map(Self.remoteHost(of:)))
                remoteHostMachines = remoteHostMachines.filter { held.contains($0.key) || $0.value == Self.contestedRemoteHost }
            }
            remoteHostMachines[host] = machine
        default:
            if remoteHostMachines[host] != Self.contestedRemoteHost {
                logger.error("remote chat names: host \(host, privacy: .public) claimed by two machines; its names are dropped")
                remoteHostMachines[host] = Self.contestedRemoteHost
                dropRemote(host: host)
            }
            return
        }
        let key = Self.remoteKey(host: host, session: session)
        let record: Session
        if let held = remoteSessions[key] {
            record = held
        } else {
            if remoteSessions.count >= Self.remoteLimit, let flooder = Dictionary(grouping: remoteSessions.keys, by: Self.remoteHost(of:)).max(by: { $0.value.count < $1.value.count })?.key {
                dropRemote(host: flooder) // the host noting the most, never every machine's names
            }
            if remoteSessions.keys.lazy.filter({ $0.hasPrefix(host + "\u{0}") }).count >= Self.remoteLimitPerHost { dropRemote(host: host) }
            record = Session()
            remoteSessions[key] = record
            if let signal = awaited.removeValue(forKey: key) { signal.made &+= 1 }
        }
        let title = Self.plainName(AgentTurnStates.title(summary))
        let generatedTitle = Self.plainName(AgentTurnStates.title(summary, includingPrompt: false))
        let sessionName = Self.plainName(AgentTurnStates.sessionName(summary))
        // Its given name and former names only: a remote chat's icon is never read (``remoteSummary(_:)`` drops it).
        let identity = AgentSessionIdentity.of(summary: summary).map {
            AgentSessionIdentity(displayName: Self.plainName($0.displayName), formerNames: $0.formerNames.compactMap(Self.plainName))
        }.flatMap { $0 == AgentSessionIdentity() ? nil : $0 }
        if record.title != title { record.title = title }
        if record.generatedTitle != generatedTitle { record.generatedTitle = generatedTitle }
        if record.sessionName != sessionName { record.sessionName = sessionName }
        if record.identity != identity {
            record.identity = identity
            record.iconArt = nil
        }
    }

    /// Drops every noted name of `host`; each of its readers reads its chat as unnamed.
    private func dropRemote(host: String) { dropRemote { $0.hasPrefix(host + "\u{0}") } }

    /// Drops the noted names whose key `drops` picks, clearing each record so a reader holding it reads it unnamed.
    private func dropRemote(_ drops: (String) -> Bool) {
        for key in remoteSessions.keys where drops(key) {
            let record = remoteSessions.removeValue(forKey: key)
            record?.title = nil
            record?.generatedTitle = nil
            record?.sessionName = nil
            record?.identity = nil
        }
    }

    /// Whether the names `ref` reads are another machine's (``noteRemote(_:host:machine:)``), not this Mac's own chat's.
    /// Those never pick a name the person's own act keeps (Name from Activity) nor keep a name they gave a workspace.
    public func namesAreRemote(_ ref: AgentSessionRef) -> Bool {
        guard let session = ref.session, ref.host != localHost, !mirroredHosts.contains(ref.host) else { return false }
        return remoteSessions[Self.remoteKey(host: ref.host, session: session)] != nil
    }

    /// The noted names of the chat `ref` shows when it runs on another machine; nil for this Mac's chats and
    /// before its page noted any, after observing that chat's own signal so the reader reads again once noted.
    func remote(_ ref: AgentSessionRef) -> Session? {
        guard let session = ref.session, ref.host != localHost, !mirroredHosts.contains(ref.host) else { return nil }
        let key = Self.remoteKey(host: ref.host, session: session)
        if let record = remoteSessions[key] { return record }
        let signal = awaited[key] ?? {
            let made = AgentTurnRecordSignal()
            awaited[key] = made
            return made
        }()
        _ = signal.made
        return nil
    }
}
