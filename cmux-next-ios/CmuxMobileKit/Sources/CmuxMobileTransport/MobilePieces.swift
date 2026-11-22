import Foundation
import os
#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif

/// The phone's kill switch (SECURITY.md "What the phone takes remotely"): which built-in
/// pieces of the app a signed file has switched **off**, back to the fallback compiled into
/// the app. It downloads no code. Removing the switch turns the piece on again.
///
/// Swift only holds the answer. Rust (`cmux-web-pieces`, `cmux-mobile-link`'s `pieces`)
/// decides which builds read a file at all (today cmux INTERNAL only; the App Store app does
/// not), fetches it, checks its signature against the pinned key, refuses an older or
/// oversize one, keeps the last file taken and writes the log.
///
/// The first question a launch asks (`isOff`) reads the last file taken from the disk, so a
/// piece switched off stays off before it first shows. A check after launch (`check`) holds
/// its answer until `applyChecked`, which the shell calls as the app leaves or enters the
/// foreground, never in the middle of drawing a screen; a change is posted
/// (`didChangeNotification`) so open screens follow it.
public final class MobilePieces: Sendable {
    /// A piece the file can switch off. The names are Rust's (`cmux_web_pieces::phone::PIECES`).
    public enum Piece: String, Sendable, CaseIterable {
        /// The web renderer that draws math. Off: the native markdown renderer, math as its
        /// TeX source.
        case markdownWeb = "markdown-web"
        /// Agent CLI Screen Changes. Off: the terminal's byte stream, as with the setting off.
        case terminalAgentCLIChanges = "terminal-agent-cli-changes"
        /// Predictive echo. Off: the Mac's own echo, as with the setting off.
        case terminalPredictiveEcho = "terminal-predictive-echo"
    }

    /// What Rust answered.
    public struct Reading: Sendable, Equatable {
        /// Whether this build reads a switch file at all.
        public var reads: Bool
        /// The pieces switched off, by Rust's name, each with the file's reason.
        public var off: [String: String]
        /// The serial of the last file taken.
        public var serial: UInt64
        /// `taken`, `no_file`, `fresh`, a refusal's code, or `off`.
        public var verdict: String

        public init(reads: Bool = false, off: [String: String] = [:], serial: UInt64 = 0, verdict: String = "off") {
            self.reads = reads
            self.off = off
            self.serial = serial
            self.verdict = verdict
        }
    }

    /// The Rust calls, replaceable in tests.
    public struct Core: Sendable {
        /// The last file taken, from the disk alone.
        public var load: @Sendable () -> Reading
        /// One check of the published file.
        public var check: @Sendable () async -> Reading

        public init(load: @escaping @Sendable () -> Reading, check: @escaping @Sendable () async -> Reading) {
            self.load = load
            self.check = check
        }
    }

    private struct State {
        var applied: Reading?
        var checked: Reading?
    }

    public static let shared = MobilePieces(core: .live)

    private let core: Core
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(core: Core) {
        self.core = core
    }

    /// Whether `piece` is switched off. The first call of a launch reads the disk through Rust.
    public func isOff(_ piece: Piece) -> Bool {
        applied.off[piece.rawValue] != nil
    }

    /// What the app holds now.
    ///
    /// The first read loads the disk through Rust outside the lock, so no other thread waits
    /// on file I/O. Two first reads may both load; the first answer stored stays, and an
    /// answer applied while a load was out (`applyChecked`) is never replaced by the load.
    public var applied: Reading {
        if let applied = state.withLock({ $0.applied }) { return applied }
        let loaded = core.load()
        return state.withLock { state in
            if let applied = state.applied { return applied }
            state.applied = loaded
            return loaded
        }
    }

    /// Reads the published file (at most one request; Rust skips it when the last answer is
    /// recent) and holds the answer for `applyChecked`. Never throws; a failed read or a
    /// refused file answers with what the phone already holds.
    public func check() async {
        guard applied.reads else { return }
        let checked = await core.check()
        state.withLock { $0.checked = checked }
    }

    /// Posted (object: the `MobilePieces`) when `applyChecked` changes which pieces are off.
    /// Open screens that read a piece once follow it here: a terminal's predictive echo and
    /// its Agent CLI Screen Changes, and the chat's native row layouts.
    public static let didChangeNotification = Notification.Name("cmux.mobilePieces.didChange")

    /// Makes the last check's answer the one `isOff` gives. Returns whether anything changed,
    /// and when it did posts `didChangeNotification` (after the lock is let go).
    @discardableResult
    public func applyChecked() -> Bool {
        let changed = state.withLock { state in
            guard let checked = state.checked else { return false }
            state.checked = nil
            let changed = state.applied?.off != checked.off
            state.applied = checked
            return changed
        }
        if changed { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        return changed
    }
}

extension MobilePieces.Core {
    /// The folder Rust keeps the last file taken and the log in.
    static var folder: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("cmux-pieces", isDirectory: true).path
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static let live: MobilePieces.Core = {
        #if canImport(CmuxMobileLinkFFI)
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let folder = MobilePieces.Core.folder
        let debug = MobilePieces.Core.isDebugBuild
        return MobilePieces.Core(
            load: { MobilePieces.Reading(piecesLoad(dir: folder, bundleId: bundle, debug: debug)) },
            check: { MobilePieces.Reading(await piecesCheck(dir: folder, bundleId: bundle, debug: debug)) }
        )
        #else
        // No Rust core (macOS package tests): nothing is read and nothing is switched.
        return MobilePieces.Core(load: { MobilePieces.Reading() }, check: { MobilePieces.Reading() })
        #endif
    }()
}

#if canImport(CmuxMobileLinkFFI)
extension MobilePieces.Reading {
    init(_ reading: PiecesReading) {
        self.init(
            reads: reading.reads,
            off: Dictionary(reading.off.map { ($0.piece, $0.reason) }, uniquingKeysWith: { first, _ in first }),
            serial: reading.serial,
            verdict: reading.verdict
        )
    }
}
#endif
