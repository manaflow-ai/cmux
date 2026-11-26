public import Foundation

/// The random id a report carries instead of anything that names the person or the Mac: a UUID
/// made here, replaced every 30 days (Rust's rule, asked through ``HangReportRules``), never derived from hardware, an account or
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

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// The id to send now: the stored one while the rules keep it, else a new one.
    public func current() -> String {
        struct Request: Encodable {
            var id: String?
            var created: Double?
            var now: Double
        }
        let defaults = defaults
        let date = now()
        let stored = defaults.string(forKey: Self.idKey)
        let request = Request(id: stored, created: (defaults.object(forKey: Self.createdKey) as? Date)?.timeIntervalSince1970,
                              now: date.timeIntervalSince1970)
        if let stored, HangReportRules.call("install_id", request, as: HangReportRules.Keep.self)?.keep == true {
            return stored
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
