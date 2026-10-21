import Foundation

/// Which settings problems the app tells the person about, and when. A load
/// never fails on a bad entry: the entry is skipped and reported in
/// ``SettingsDiagnostic``. Without a notice an agent or a hand edit could set
/// a value this build refuses (a background form it does not know, a wrong
/// type) and the app would silently fall back to the default.
///
/// A notice is the key, the value the file holds there and the reason. Each
/// one is announced once: the same refusal on a later reload or launch stays
/// quiet (the app keeps ``remembered`` across launches), a different bad
/// value at the key is announced, and a refusal that was fixed is announced
/// again when it comes back. Managed keys (MDM, team policy) and
/// shortcut conflicts are not announced: the person did not set the first and
/// the defaults alone can make the second; Settings lists both at their rows.
public struct SettingsDiagnosticNotices: Sendable {
    public struct Notice: Sendable, Hashable {
        /// Dotted key ("" for the whole file).
        public let path: String
        /// The file's value at the key as compact JSON, nil when it has none.
        public let value: String?
        public let message: String
        public init(path: String, value: String?, message: String) {
            self.path = path
            self.value = value
            self.message = message
        }

        /// What ``remembered`` stores for it.
        var fingerprint: String { [path, value ?? "", message].joined(separator: "\u{0}") }
    }

    public struct Update: Sendable, Equatable {
        /// Refusals not announced before, in the load's order.
        public let announce: [Notice]
        /// The last announced refusals are all gone: a shown notice can close.
        public let cleared: Bool
    }

    /// Fingerprints of the refusals announced and not fixed since: the last
    /// load's, or at launch the ones an earlier launch announced.
    public private(set) var remembered: Set<String>

    public init(remembered: Set<String> = []) {
        self.remembered = remembered
    }

    /// The kinds that mean the file's own value was dropped.
    public static func announces(_ kind: SettingsDiagnostic.Kind) -> Bool {
        switch kind {
        case .unreadableFile, .invalidValue, .unknownAction, .unknownMetric, .unsupportedChord, .removedSetting: true
        case .shortcutConflict, .managedOverride, .managedConflict: false
        }
    }

    /// Takes one load's diagnostics and the user's file (`SettingsController.fileRoot`).
    public mutating func update(_ diagnostics: [SettingsDiagnostic], file: JSONValue) -> Update {
        var seen: Set<String> = []
        var fresh: [Notice] = []
        for diagnostic in diagnostics where Self.announces(diagnostic.kind) {
            let value = diagnostic.path.isEmpty ? nil : file.value(at: CmuxConfigFile.keyPath(from: diagnostic.path))?.compactText
            let notice = Notice(path: diagnostic.path, value: value, message: diagnostic.message)
            guard seen.insert(notice.fingerprint).inserted else { continue }
            if !remembered.contains(notice.fingerprint) { fresh.append(notice) }
        }
        let cleared = seen.isEmpty && !remembered.isEmpty
        remembered = seen
        return Update(announce: fresh, cleared: cleared)
    }
}
