extension DaemonNotification {
    /// The poster's subtitle (`cmux notify --subtitle`), unless empty.
    public var shownSubtitle: String? { subtitle.flatMap { $0.isEmpty ? nil : $0 } }
}
