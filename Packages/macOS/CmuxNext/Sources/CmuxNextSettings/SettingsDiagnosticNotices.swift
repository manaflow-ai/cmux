import Foundation

/// Which settings problems the app tells the person about, and when (the
/// first version, with the review's new entry points; see the tests).
public struct SettingsDiagnosticNotices: Sendable {
    public struct Notice: Sendable, Hashable {
        public let path: String
        public let value: String?
        public let message: String
        public let fingerprint: String
        public init(kind: SettingsDiagnostic.Kind = .invalidValue, path: String, value: String?, message: String) {
            self.path = path
            self.value = value
            self.message = message
            fingerprint = [path, value ?? "", message].joined(separator: "\u{0}")
        }
    }

    public struct Update: Sendable, Equatable {
        public let announce: [Notice]
        public let cleared: Bool
    }

    public private(set) var remembered: Set<String>

    public init(remembered: Set<String> = []) {
        self.remembered = remembered
    }

    public static func announces(_ kind: SettingsDiagnostic.Kind) -> Bool {
        switch kind {
        case .unreadableFile, .invalidValue, .unknownAction, .unknownMetric, .unsupportedChord, .removedSetting: true
        case .shortcutConflict, .managedOverride, .managedConflict: false
        }
    }

    public mutating func update(_ diagnostics: [SettingsDiagnostic], file: JSONValue, managed: Set<String> = []) -> Update {
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

    public mutating func announced(_ notices: [Notice]) {}
}
