/// `history.closed.maxGroups` and `history.closed.maxAgeDays` in cmux.json
/// (reopen-closed.md S1b): how much recently closed history each machine
/// keeps. 0, the default, keeps everything. The App applies them with
/// `closed.delete`; the daemon stores no limit.
public struct ClosedHistoryRetentionSetting: Sendable, Equatable {
    /// Groups each machine keeps; 0 keeps every group.
    public var maxGroups: Int
    /// Days each machine keeps a group; 0 keeps groups of any age.
    public var maxAgeDays: Int

    public init(maxGroups: Int = Int(ClosedHistoryRetentionSetting.maxGroupsDefault), maxAgeDays: Int = Int(ClosedHistoryRetentionSetting.maxAgeDaysDefault)) {
        self.maxGroups = maxGroups
        self.maxAgeDays = maxAgeDays
    }

    /// The limits in `root`; a bad value counts as 0 (diagnosed when the
    /// snapshot is parsed).
    public init(root: JSONValue) {
        var diagnostics: [SettingsDiagnostic] = []
        self = Self.parse(root, diagnostics: &diagnostics)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        func value(_ path: [String], _ range: ClosedRange<Double>, _ fallback: Double, _ expected: String) -> Int {
            guard let raw = root.value(at: path) else { return Int(fallback) }
            guard let number = raw.intValue, range.contains(Double(number)) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."),
                                                      message: expected))
                return Int(fallback)
            }
            return number
        }
        return Self(maxGroups: value(maxGroupsPath, maxGroupsRange, maxGroupsDefault, "expected a whole number of groups from 0 to 10000, such as 200"),
                    maxAgeDays: value(maxAgeDaysPath, maxAgeDaysRange, maxAgeDaysDefault, "expected a whole number of days from 0 to 3650, such as 30"))
    }
}

extension CmuxConfigSnapshot {
    /// `history.*`: terminal command recording and its retention, and the
    /// diagnostics of `history.closed.*` (read where they apply).
    mutating func parseHistory(_ root: JSONValue) {
        parseTerminalCommandHistory(root)
        _ = ClosedHistoryRetentionSetting.parse(root, diagnostics: &diagnostics)
    }
}
