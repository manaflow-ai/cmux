public import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation
import os

/// The `TERM` new terminals get (Lawrence 2026-10-28: "default echo $TERM should not use the ghostty one but
/// should use the standard one that every tool recognizes, for all cmux").
///
/// ``standard`` (`xterm-256color`) unless the person asks for another: cmux.json's `terminal.term`
/// (``setting``), else an explicit `term = ...` in their Ghostty config files (``ghosttyConfig``). Ghostty's
/// own default (`xterm-ghostty`) is never used on its own: ssh targets, VMs, containers and older tools lack
/// that terminfo entry. `COLORTERM=truecolor` and `TERM_PROGRAM=ghostty` still say what the terminal can do.
/// A name other than ``standard`` is used only when ``TerminfoLookup`` finds its entry on this Mac.
public nonisolated struct TerminalTermChoice: Sendable, Equatable {
    /// The `TERM` every tool and every ssh host knows.
    public static let standard = "xterm-256color"
    /// The env key a spawn carries the chosen `TERM` in when it is not ``standard``: the daemon records it, and a
    /// restored, reopened or respawned terminal gets it back as its `TERM` (cmux-tui `relaunch_store::chosen_term`).
    public static let recordKey = "CMUX_TERM_CHOICE"

    /// `terminal.term` in cmux.json; nil when unset.
    public var setting: String?
    /// The Ghostty config files' explicit `term` (``GhosttyConfigTerm``); nil when they set none.
    public var ghosttyConfig: String?

    public init(setting: String? = nil, ghosttyConfig: String? = nil) {
        self.setting = setting
        self.ghosttyConfig = ghosttyConfig
    }

    /// The name asked for: the setting, else the Ghostty config's, else ``standard``.
    public var requested: String { setting ?? ghosttyConfig ?? Self.standard }

    /// Whether `name` can be a terminfo name: 1 to 64 letters, digits, `.`, `_`, `+` or `-`, not starting with
    /// `.` or `-` (it becomes a path under a terminfo folder and a value in every shell's environment).
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), let first = name.utf8.first, first != UInt8(ascii: "."), first != UInt8(ascii: "-") else {
            return false
        }
        return name.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
        }
    }
}

/// Finds whether a terminfo entry is installed where ncurses looks by default, for a `TERM` other than
/// ``TerminalTermChoice/standard``. The check reads the disk, so it runs on the files lane, until it finds the
/// entry (then once per launch); the standard name reads nothing. A name with no entry gives the standard one and a log line.
public nonisolated final class TerminfoLookup: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "terminal")
    /// The lanes the check runs on; nil finds no entry (tests and processes with no lanes).
    private let work: BackgroundWork?
    private let home: String
    private let fileExists: @Sendable (String) -> Bool
    // Lock carve-out: one dictionary read or write per spawn of a non-standard TERM, no I/O under it.
    private let found = Mutex<[String: Bool]>([:])

    public init(work: BackgroundWork?, home: String = NSHomeDirectory(),
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) }) {
        self.work = work
        self.home = home
        self.fileExists = fileExists
    }

    /// The `TERM` for `requested`: itself when it is ``TerminalTermChoice/standard`` or its entry is installed,
    /// else the standard one, logged.
    public func term(for requested: String) async -> String {
        let standard = TerminalTermChoice.standard
        guard requested != standard else { return standard }
        guard TerminalTermChoice.isValidName(requested) else {
            Self.logger.warning("TERM \(requested, privacy: .public) is not a terminfo name; new terminals use \(standard, privacy: .public)")
            return standard
        }
        if await installed(requested) { return requested }
        Self.logger.warning("no terminfo entry for \(requested, privacy: .public) on this Mac; new terminals use \(standard, privacy: .public)")
        return standard
    }

    private func installed(_ name: String) async -> Bool {
        if let known = found.withLock({ $0[name] }) { return known }
        guard let work else { return false }
        let (home, fileExists) = (home, fileExists)
        let installed = (try? await work.run(.userBlocking, mayBlock: .files) { Self.isInstalled(name, home: home, fileExists: fileExists) }) ?? false
        // Only a hit is kept: an entry installed after a miss is found by the next terminal.
        if installed { found.withLock { $0[name] = true } }
        return installed
    }

    /// Whether `name`'s entry is in a terminfo folder ncurses searches by default (`~/.terminfo` and the system
    /// folders, by first letter or by its hex code). The app's bundled entries are not: ssh targets lack them.
    public static func isInstalled(_ name: String, home: String, fileExists: (String) -> Bool) -> Bool {
        guard let first = name.utf8.first else { return false }
        let letter = String(UnicodeScalar(first)), hex = String(format: "%02x", first)
        let roots = [home + "/.terminfo", "/usr/share/terminfo", "/usr/lib/terminfo", "/etc/terminfo", "/lib/terminfo",
                     "/opt/homebrew/share/terminfo", "/usr/local/share/terminfo"]
        return roots.contains { fileExists("\($0)/\(hex)/\(name)") || fileExists("\($0)/\(letter)/\(name)") }
    }
}
