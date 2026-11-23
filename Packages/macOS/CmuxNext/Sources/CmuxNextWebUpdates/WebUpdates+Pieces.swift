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
//
// A drill (`updates.web.pieces.check` with `drill`) reads its own file into `pieces-drill/`: its
// state, log and kept file live there, and the CLI only reports (`drill_refused_active`) the
// active update its file refuses, so a drill never rolls back or blocks a real update. Ending it
// serves what the channel's own state and kept file say again.

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
    /// A drill's file refuses the active update: only reported (the CLI never sets
    /// `refusedActive` for a drill).
    let drillRefusedActive: Bool?
    let serial: Int?
    /// Why the newest file read was not taken (the last one taken still holds).
    let refusal: Refusal?

    enum CodingKeys: String, CodingKey {
        case pieces, serial, refusal
        case refusedActive = "refused_active"
        case drillRefusedActive = "drill_refused_active"
    }

    /// The pieces not served from the active update.
    var switched: [String: Piece] { pieces.filter { $0.value.serve != "live" } }

    /// The answer in the last line of the command's output, nil when it is none.
    static func parse(_ output: Data) -> WebPiecesAnswer? { lastLine(output, as: WebPiecesAnswer.self) }

    /// The last non-empty line of a `cmux app web-pieces` output as `T`, nil when it is none.
    static func lastLine<T: Decodable>(_ output: Data, as type: T.Type) -> T? {
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }) else { return nil }
        return try? JSONDecoder().decode(type, from: Data(line))
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
        var status: [String: JSONValue] = ["serial": taken, "refusal": refused, "switched": .object(out)]
        if let drillRefusedActive { status["drill_refused_active"] = .bool(drillRefusedActive) }
        return .object(status)
    }
}

/// The answer of `cmux app web-pieces refused`: whether the switch file last taken refuses an update.
nonisolated struct WebPiecesRefused: Decodable, Equatable, Sendable {
    let refused: Bool

    static func parse(_ output: Data) -> WebPiecesRefused? { WebPiecesAnswer.lastLine(output, as: WebPiecesRefused.self) }
}

/// The folders of kept updates that verified (``WebUpdateStore/verifiedTree(_:)`` hashes every
/// file), by key, for the set of kept updates they were verified for. A new set starts empty.
nonisolated struct VerifiedTrees: Equatable, Sendable {
    private(set) var keys: Set<String> = []
    private(set) var trees: [String: URL] = [:]

    /// The folders verified for `keys`: empty, and the cache reset, when the set changed.
    mutating func held(for keys: Set<String>) -> [String: URL] {
        if keys != self.keys {
            self.keys = keys
            trees = [:]
        }
        return trees
    }

    /// Keeps `verified` when it was verified for the set held now.
    mutating func add(_ verified: [String: URL], for keys: Set<String>) {
        guard keys == self.keys else { return }
        trees.merge(verified) { _, new in new }
    }
}

extension WebUpdates {
    /// The pointers of the updates switched-out pieces are served from, in the CLI's state folder
    /// (``piecesPlace(_:_:drill:)``: the web updates folder, or `pieces-drill/` in a drill).
    nonisolated static let keptFile = "web-pieces-kept.json"
    /// The CLI's state file (cmux-tui `web_pieces::STATE_FILE`): a switch file was taken here once.
    nonisolated static let stateFile = "web-pieces.json"

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
    /// ran stay out, and a kept update the switch file refuses is not served. Runs the CLI only
    /// when a piece was switched out, or when there is a kept update and a switch file was taken
    /// once (only a taken file can refuse it). Returns whether the switch file refuses the kept
    /// update (the launch then serves the bundled web until the roll back is saved).
    func restorePieces(_ updater: WebUpdater) async -> Bool {
        guard let piecesCLI else { return false }
        let base = updater.store.base
        var ask = await Self.has(Self.keptFile, in: base)
        if !ask, updater.state.active != nil { ask = await Self.has(Self.stateFile, in: base) }
        guard ask else { return false }
        let refused = await readPiecesNow(updater, piecesCLI, offline: true, launch: true)
        if refused { readPieces(offline: true) }
        return refused
    }

    /// Whether the switch file last taken refuses `pointer` (`cmux app web-pieces refused`: offline,
    /// from the state the reads kept; the decision is Rust's). The updater asks it before it
    /// downloads a new update and makes it active, so a refused update is never served. No answer:
    /// not refused here (the pieces read after the check still rolls it back).
    func piecesRefuse(_ pointer: WebUpdatePointer, _ updater: WebUpdater) async -> Bool {
        guard let piecesCLI, updater.channel != .off else { return false }
        let (state, channel) = Self.piecesPlace(updater.store, updater.channel, drill: piecesDrill)
        let words = ["app", "web-pieces", "refused", "--state", state.path, "--channel", channel, "--key", pointer.key]
        guard let output = await piecesCLI(words) else { return false }
        return WebPiecesRefused.parse(output)?.refused ?? false
    }

    /// The state folder and the channel the CLI reads. A drill has its own file, serial and log,
    /// so it never moves the channel's own.
    nonisolated static func piecesPlace(_ store: WebUpdateStore, _ channel: WebUpdater.Channel, drill: Bool) -> (URL, String) {
        let state = drill ? store.base.appending(path: "pieces-drill", directoryHint: .isDirectory) : store.base
        return (state, (drill ? "drill-" : "") + channel.rawValue)
    }

    /// One read. Returns whether the active update is refused and was not rolled back here.
    /// Internal for the tests (WebPiecesHostTests).
    func readPiecesNow(_ updater: WebUpdater, _ cli: @Sendable ([String]) async -> Data?,
                       offline: Bool, launch: Bool, rolledBack: Int = 0) async -> Bool {
        let channel = updater.channel, store = updater.store
        let drill = piecesDrill
        let (state, piecesChannel) = Self.piecesPlace(store, channel, drill: drill)
        guard channel != .off else {
            // Off serves the bundled web: nothing is switched.
            pieces = nil
            await Self.keep([], in: state)
            if WebBundleOverlay.shared.setSwitches([:]), !launch { await switchesChanged() }
            return false
        }
        let active = updater.state.active
        // The update a piece is served from now comes first, so the piece stays on it.
        var candidates: [WebUpdatePointer] = []
        for pointer in await Self.kept(in: state) + [updater.state.previous].compactMap({ $0 })
        where pointer.key != active?.key && !candidates.contains(where: { $0.key == pointer.key }) {
            candidates.append(pointer)
        }
        var words = ["app", "web-pieces", "check", "--state", state.path, "--channel", piecesChannel]
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
        let keys = Set(candidates.map(\.key))
        let (switched, used, verified) = await Self.resolve(answer, candidates, store, verified: verifiedTrees.held(for: keys))
        verifiedTrees.add(verified, for: keys)
        pieces = answer
        await Self.keep(used, switched: !switched.isEmpty, in: state)
        if WebBundleOverlay.shared.setSwitches(switched), !launch { await switchesChanged() }
        return false
    }

    /// The folder each switched-out output is served from (nil: the bundle), the pointers of the
    /// updates used, and the folders verified here. An update is used only while its files still
    /// match its signed pointer; else the piece is served from the bundle. `verified`: the folders
    /// already verified in this run (``VerifiedTrees``), not hashed again.
    @concurrent nonisolated static func resolve(_ answer: WebPiecesAnswer, _ pointers: [WebUpdatePointer], _ store: WebUpdateStore,
                                                verified: [String: URL] = [:]) async -> ([String: URL?], [WebUpdatePointer], [String: URL]) {
        var trees: [String: URL?] = [:]
        var used: [WebUpdatePointer] = []
        var switched: [String: URL?] = [:]
        var fresh: [String: URL] = [:]
        for piece in answer.switched.values {
            var tree: URL?
            if let key = piece.update {
                if let known = trees[key] {
                    tree = known
                } else {
                    let pointer = pointers.first { $0.key == key }
                    if let pointer {
                        if let cached = verified[key] {
                            tree = cached
                        } else {
                            tree = store.verifiedTree(pointer)
                            if let tree { fresh[key] = tree }
                        }
                    }
                    trees.updateValue(tree, forKey: key)
                    if tree != nil, let pointer { used.append(pointer) }
                }
            }
            switched.updateValue(tree, forKey: piece.output)
        }
        return (switched, used, fresh)
    }

    @concurrent nonisolated static func has(_ file: String, in folder: URL) async -> Bool {
        FileManager.checked.fileExists(atPath: folder.appending(path: file).path)
    }

    /// The kept pointers in `folder` (the CLI's state folder).
    @concurrent nonisolated static func kept(in folder: URL) async -> [WebUpdatePointer] {
        guard let data = try? Data(blockingContentsOf: folder.appending(path: keptFile)) else { return [] }
        return (try? JSONDecoder().decode(Kept.self, from: data))?.pointers ?? []
    }

    /// Keeps `pointers` in `folder` (the CLI's state folder) while a piece is switched out; with
    /// none switched the file goes.
    @concurrent nonisolated static func keep(_ pointers: [WebUpdatePointer], switched: Bool = false, in folder: URL) async {
        let file = folder.appending(path: keptFile)
        guard switched else {
            if FileManager.checked.fileExists(atPath: file.path) { try? FileManager.checked.removeItem(at: file) }
            return
        }
        try? FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Kept(pointers: pointers)).blockingWrite(to: file, options: .atomic)
    }
}
