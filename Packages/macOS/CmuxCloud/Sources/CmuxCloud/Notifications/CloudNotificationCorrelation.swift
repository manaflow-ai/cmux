import Foundation

/// Correlation keys tie a local notification back to its Cloud machine and
/// daemon row so reads can be acknowledged without guessing from text.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum CloudNotificationCorrelation: Sendable {
    public static let prefix = "cloud-notification:"
    private static let versionedPrefix = "v2:"

    public static func key(machineID: String, notificationID: String) -> String {
        "\(prefix)\(versionedPrefix)\(encode(machineID)):\(encode(notificationID))"
    }

    public static func parse(_ key: String) -> (machineID: String, notificationID: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        if rest.hasPrefix(versionedPrefix) {
            let components = rest.dropFirst(versionedPrefix.count)
                .split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 2,
                  let machineID = decode(String(components[0])),
                  let notificationID = decode(String(components[1])),
                  !machineID.isEmpty,
                  !notificationID.isEmpty else { return nil }
            return (machineID, notificationID)
        }

        // Notifications persisted by older builds used the delimiter format.
        // Keep reading those records while all new keys use the unambiguous form.
        guard let separator = rest.lastIndex(of: ":") else { return nil }
        let machineID = String(rest[..<separator])
        let notificationID = String(rest[rest.index(after: separator)...])
        guard !machineID.isEmpty, !notificationID.isEmpty else { return nil }
        return (machineID, notificationID)
    }

    /// Matches either the current or legacy key format to a daemon event.
    public static func matches(_ key: String, machineID: String, notificationIDs: Set<String>) -> Bool {
        guard let source = parse(key) else { return false }
        return source.machineID == machineID && notificationIDs.contains(source.notificationID)
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func decode(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
