import Foundation

/// Which settings problems the app tells the person about (stub; see the tests).
public struct SettingsDiagnosticNotices: Sendable {
    public struct Notice: Sendable, Hashable {
        public let path: String
        public let value: String?
        public let message: String
        public init(path: String, value: String?, message: String) {
            self.path = path
            self.value = value
            self.message = message
        }
    }

    public struct Update: Sendable, Equatable {
        public let announce: [Notice]
        public let cleared: Bool
    }

    public init() {}

    public mutating func update(_ diagnostics: [SettingsDiagnostic], file: JSONValue) -> Update {
        Update(announce: [], cleared: false)
    }
}
