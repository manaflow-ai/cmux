public import Foundation

/// The random id a report carries instead of anything that names the person or the Mac: a UUID
/// made here, replaced every ``rotation`` (30 days), never derived from hardware, an account or
/// another id. ``HangReportService`` owns it; turning hang reports off forgets it.
///
/// ```swift
/// let identity = InstallIdentity(suiteName: "hang-reports-test", now: { fixedDate })
/// let id = identity.current()
/// ```
/// It keeps the defaults domain's name, not a `UserDefaults` object (which is not `Sendable`), and
/// opens the domain at each call; nil is the app's own domain.
public nonisolated struct InstallIdentity: Sendable {
    /// The defaults key of the id.
    public static let idKey = "cmux.next.hangReports.installId"
    /// The defaults key of the id's creation date.
    public static let createdKey = "cmux.next.hangReports.installIdCreated"
    /// How long one id lives.
    public static let rotation: TimeInterval = 30 * 24 * 60 * 60

    private let suiteName: String?
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    /// - Parameter suiteName: The defaults domain (nil: the app's standard domain; tests pass their own).
    public init(suiteName: String? = nil, now: @escaping @Sendable () -> Date = Date.init,
                makeID: @escaping @Sendable () -> UUID = UUID.init) {
        self.suiteName = suiteName
        self.now = now
        self.makeID = makeID
    }

    /// The id to send now: the stored one while it is younger than ``rotation``, else a new one.
    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// The id to send now: the stored one while younger than ``rotation``, else a new one.
    public func current() -> String {
        let defaults = defaults
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
        let defaults = defaults
        defaults.removeObject(forKey: Self.idKey)
        defaults.removeObject(forKey: Self.createdKey)
    }
}
