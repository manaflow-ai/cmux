import CmuxNextCompat
import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings
import CmuxNextUpdater
import Foundation

// The web pieces switched out remotely (cmuxterm-hq docs/design/ship-without-update.md). A web
// update is five pieces (the agent pane, the pages, Agent Activity, the viewers, the inspector).
// The channel's signed switch file names the pieces to serve from the last good update or from
// the app's own bundle instead of the active update, and the updates never to serve. Every
// decision is Rust: `cmux app web-pieces check` (cmux-tui/crates/cmux-web-pieces) fetches the
// file, checks its signature against the pinned web update key, keeps its serial and its log,
// and prints what each piece is served from. This file only runs it after each update check, maps
// the answer onto the folders on disk (``WebBundleOverlay/setSwitches(_:)``) and reloads the open
// pages of a switched piece at their safe points.
//
// A read that fails keeps what is served. The update a piece was switched back to is kept on
// disk, with its signed pointer in `web-pieces-kept.json`, until the piece is live again, so a
// later update never moves the piece onto the build it was switched away from.

/// The answer of `cmux app web-pieces check`: what each web piece is served from.
nonisolated struct WebPiecesAnswer: Decodable, Equatable, Sendable {
    nonisolated struct Piece: Decodable, Equatable, Sendable {
        /// Where the piece sits in an update (``WebUpdateTree/outputs``).
        let output: String
        /// The key of the update that serves it; nil: the app's bundle.
        let update: String?
        /// `live`, `last-good` or `bundled`.
        let serve: String
        let reason: String?
    }

    nonisolated struct Refusal: Decodable, Equatable, Sendable {
        let code: String
        let message: String
    }

    let pieces: [String: Piece]
    /// The switch file refuses the active update: the app rolls it back.
    let refusedActive: Bool
    let serial: Int?
    /// Why the newest file read was not taken (the last one taken still holds).
    let refusal: Refusal?

    enum CodingKeys: String, CodingKey {
        case pieces, serial, refusal
        case refusedActive = "refused_active"
    }

    /// The pieces not served from the active update.
    var switched: [String: Piece] { pieces.filter { $0.value.serve != "live" } }

    /// The answer in the last line of the command's output, nil when it is none.
    static func parse(_ output: Data) -> WebPiecesAnswer? {
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }) else { return nil }
        return try? JSONDecoder().decode(WebPiecesAnswer.self, from: Data(line))
    }

    /// For `updates.web.status`.
    var json: JSONValue {
        var out: [String: JSONValue] = [:]
        for (name, piece) in switched {
            let update: JSONValue = piece.update.map { .string($0) } ?? .null
            out[name] = .object(["serve": .string(piece.serve), "update": update, "reason": .string(piece.reason ?? "")])
        }
        let taken: JSONValue = serial.map { JSONValue($0) } ?? .null
        let refused: JSONValue = refusal.map { .string($0.code) } ?? .null
        return .object(["serial": taken, "refusal": refused, "switched": .object(out)])
    }
}

extension WebUpdates {
    /// The pointers of the updates switched-out pieces are served from, in the web updates folder.
    nonisolated static let keptFile = "web-pieces-kept.json"

    nonisolated struct Kept: Codable, Sendable {
        var pointers: [WebUpdatePointer]
    }

    /// Reads the channel's switch file (`offline`: only what the last read kept) after the read
    /// that runs now, and serves what it says. Nil where web updates do not run.
    @discardableResult
    func readPieces(offline: Bool) -> Task<Void, Never>? {
        guard let updater, let piecesCLI else { return nil }
        let before = piecesRead
        // task-owner: one read of the switch file; it ends by itself (the CLI run is bounded)
        let task = Task { [weak self] in
            await before?.value
            _ = await self?.readPiecesNow(updater, piecesCLI, offline: offline, launch: false)
        }
        piecesRead = task
        return task
    }

    /// `updates.web.pieces.check`: one read now, then the status.
    func piecesChecked(drill: Bool? = nil) async -> JSONValue {
        if let drill { piecesDrill = drill }
        await readPieces(offline: false)?.value
        return Self.json(self)
    }

    /// At launch, before the first page loads: the pieces that were switched out when cmux last
    /// ran stay out. Runs the CLI only when one was. Returns whether the switch file refuses the
    /// kept update (the launch then serves the bundled web until the roll back is saved).
    func restorePieces(_ updater: WebUpdater) async -> Bool {
        guard let piecesCLI, await Self.hasKept(updater.store) else { return false }
        let refused = await readPiecesNow(updater, piecesCLI, offline: true, launch: true)
        if refused { readPieces(offline: true) }
        return refused
    }

    /// One read. Returns whether the active update is refused and was not rolled back here.
    private func readPiecesNow(_ updater: WebUpdater, _ cli: @Sendable ([String]) async -> Data?,
                               offline: Bool, launch: Bool, rolledBack: Int = 0) async -> Bool {
        let channel = updater.channel, store = updater.store
        guard channel != .off else {
            // Off serves the bundled web: nothing is switched.
            pieces = nil
            await Self.keep([], in: store)
            if WebBundleOverlay.shared.setSwitches([:]), !launch { await switchesChanged() }
            return false
        }
        let active = updater.state.active
        // The update a piece is served from now comes first, so the piece stays on it.
        var candidates: [WebUpdatePointer] = []
        for pointer in await Self.kept(store) + [updater.state.previous].compactMap({ $0 })
        where pointer.key != active?.key && !candidates.contains(where: { $0.key == pointer.key }) {
            candidates.append(pointer)
        }
        // A drill has its own file, serial and log, so it never moves the channel's own.
        let drill = piecesDrill
        var words = ["app", "web-pieces", "check", "--state", (drill ? store.base.appending(path: "pieces-drill", directoryHint: .isDirectory) : store.base).path,
                     "--channel", (drill ? "drill-" : "") + channel.rawValue]
        if let active { words += ["--active", active.key] }
        for pointer in candidates { words += ["--kept", pointer.key] }
        if offline { words.append("--offline") }
        // No answer (no CLI, a failed run): what is served stays.
        guard let output = await cli(words), let answer = WebPiecesAnswer.parse(output) else { return false }
        guard updater.channel == channel, updater.state.active?.key == active?.key, piecesDrill == drill else { return false }
        if answer.refusedActive, active != nil {
            guard !launch else { return true }
            // Rolled back like `updates.web.rollback`: the update before it (the bundled web when
            // none), and it is never taken again. A check running now refuses; its end reads again.
            guard rolledBack < 2, (try? await updater.rollBack()) != nil else { return true }
            return await readPiecesNow(updater, cli, offline: true, launch: false, rolledBack: rolledBack + 1)
        }
        let (switched, used) = await Self.resolve(answer, candidates, store)
        pieces = answer
        await Self.keep(used, switched: !switched.isEmpty, in: store)
        if WebBundleOverlay.shared.setSwitches(switched), !launch { await switchesChanged() }
        return false
    }

    /// The folder each switched-out output is served from (nil: the bundle), and the pointers of
    /// the updates used. An update is used only while its files still match its signed pointer;
    /// else the piece is served from the bundle.
    @concurrent nonisolated static func resolve(_ answer: WebPiecesAnswer, _ pointers: [WebUpdatePointer],
                                                _ store: WebUpdateStore) async -> ([String: URL?], [WebUpdatePointer]) {
        var trees: [String: URL?] = [:]
        var used: [WebUpdatePointer] = []
        var switched: [String: URL?] = [:]
        for piece in answer.switched.values {
            var tree: URL?
            if let key = piece.update {
                if let known = trees[key] {
                    tree = known
                } else {
                    let pointer = pointers.first { $0.key == key }
                    tree = pointer.flatMap { store.verifiedTree($0) }
                    trees.updateValue(tree, forKey: key)
                    if tree != nil, let pointer { used.append(pointer) }
                }
            }
            switched.updateValue(tree, forKey: piece.output)
        }
        return (switched, used)
    }

    @concurrent nonisolated static func hasKept(_ store: WebUpdateStore) async -> Bool {
        FileManager.checked.fileExists(atPath: store.base.appending(path: keptFile).path)
    }

    @concurrent nonisolated static func kept(_ store: WebUpdateStore) async -> [WebUpdatePointer] {
        guard let data = try? Data(blockingContentsOf: store.base.appending(path: keptFile)) else { return [] }
        return (try? JSONDecoder().decode(Kept.self, from: data))?.pointers ?? []
    }

    /// Keeps `pointers` while a piece is switched out; with none switched the file goes, and the
    /// next launch runs no CLI.
    @concurrent nonisolated static func keep(_ pointers: [WebUpdatePointer], switched: Bool = false, in store: WebUpdateStore) async {
        let file = store.base.appending(path: keptFile)
        guard switched else {
            if FileManager.checked.fileExists(atPath: file.path) { try? FileManager.checked.removeItem(at: file) }
            return
        }
        try? FileManager.checked.createDirectory(at: store.base, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Kept(pointers: pointers)).blockingWrite(to: file, options: .atomic)
    }
}
