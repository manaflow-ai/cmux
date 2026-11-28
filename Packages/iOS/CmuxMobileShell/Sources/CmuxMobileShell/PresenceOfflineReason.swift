/// Why the presence service declared an instance offline.
public enum PresenceOfflineReason: String, Codable, Sendable {
    /// The instance missed heartbeats and the service's alarm expired it.
    case timeout
    /// The host announced a clean shutdown (`stopping: true` goodbye).
    case goodbye
}
