public import Foundation

/// The random id a report carries instead of anything that names the person or the Mac: a UUID
/// made here, replaced every ``rotation`` (30 days), never derived from hardware, an account or
/// another id. ``HangReportService`` owns it; turning hang reports off forgets it.
///
/// ```swift
/// var identity = InstallIdentity(defaults: UserDefaults(suiteName: "test")!, now: { fixedDate })
/// let id = identity.current()
/// ```
public nonisolated struct InstallIdentity: Sendable {
    public static let idKey = "cmux.next.hangReports.installId"
    public static let createdKey = "cmux.next.hangReports.installIdCreated"
    /// How long one id lives.
    public static let rotation: TimeInterval = 30 * 24 * 60 * 60

    // UserDefaults is documented thread-safe; the service actor is its only writer.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = Date.init,
                makeID: @escaping @Sendable () -> UUID = UUID.init) {
        self.defaults = defaults
        self.now = now
        self.makeID = makeID
    }

    /// The id to send now: the stored one while it is younger than ``rotation``, else a new one.
    public func current() -> String {
        let date = now()
        if let id = defaults.string(forKey: Self.idKey), ImageClassifier.isUUID(id),
           let created = defaults.object(forKey: Self.createdKey) as? Date,
           created <= date, date.timeIntervalSince(created) < Self.rotation {
            return id
        }
        let id = makeID().uuidString.lowercased()
        defaults.set(id, forKey: Self.idKey)
        defaults.set(date, forKey: Self.createdKey)
        return id
    }

    /// Forgets the id (hang reports turned off): the next report starts a new one.
    public func forget() {
        defaults.removeObject(forKey: Self.idKey)
        defaults.removeObject(forKey: Self.createdKey)
    }
}
