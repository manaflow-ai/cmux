/// Correlation keys tie a local notification back to its Cloud machine and
/// daemon row so reads can be acknowledged without guessing from text.
enum CloudNotificationCorrelation {
    static let prefix = "cloud-notification:"

    static func key(machineID: String, notificationID: String) -> String {
        "\(prefix)\(machineID):\(notificationID)"
    }

    static func parse(_ key: String) -> (machineID: String, notificationID: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let separator = rest.lastIndex(of: ":") else { return nil }
        let machineID = String(rest[..<separator])
        let notificationID = String(rest[rest.index(after: separator)...])
        guard !machineID.isEmpty, !notificationID.isEmpty else { return nil }
        return (machineID, notificationID)
    }
}
