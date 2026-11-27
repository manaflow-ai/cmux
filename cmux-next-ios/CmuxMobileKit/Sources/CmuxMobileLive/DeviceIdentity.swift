import Foundation

/// Client-generated device UUIDs persisted in the Keychain (PROTOCOL.md "Devices").
///
/// Two ids: `link` dials Macs (its signaling socket carries the WireGuard
/// relay while a link is up), and `presence` holds the app's own presence
/// socket. The backend keeps one socket per device and a newer one replaces
/// the older (close 4000), so sharing one id would cut the relay whenever the
/// presence listener reconnects.
///
/// The ids belong to one account on this phone: the service binds a device id
/// to the user who registered it (`403 not_owner` for anyone else), and a Mac
/// approves a phone by its link id. So they are kept per user and survive
/// sign-out: the same account signing in again is the same phone, and its Macs
/// do not ask again (verify/persistence.md). Another account gets its own ids.
public struct DeviceIdentity: Sendable, Equatable {
    public let link: String
    public let presence: String

    public init(link: String, presence: String) {
        self.link = link
        self.presence = presence
    }

    public static let defaultService = "dev.cmux.mobile.device"
    /// The service builds up to 1.2.0 kept the ids under (the app was called cnx then). Read
    /// once and moved to ``defaultService`` so the Macs that approved this phone still know it.
    public static let legacyService = "dev.cmux.cnx.device"

    /// Reads (or creates and stores) both ids of `userID` on this phone.
    ///
    /// Migration: builds before per-user ids kept one pair (accounts `link`,
    /// `presence`) and deleted it on every sign-out, so a pair that exists
    /// belongs to the account signed in now; the first load adopts it.
    public static func load(userID: String, store: any DeviceSecretStore = KeychainSecretStore(),
                            service: String = defaultService) -> DeviceIdentity {
        DeviceIdentity(link: id(userID: userID, kind: "link", store: store, service: service),
                       presence: id(userID: userID, kind: "presence", store: store, service: service))
    }

    /// Account deletion: forgets this account's ids (the service deleted its devices).
    public static func forget(userID: String, store: any DeviceSecretStore = KeychainSecretStore(),
                              service: String = defaultService) {
        for kind in ["link", "presence"] { store.delete(service: service, account: account(kind, userID)) }
    }

    static func account(_ kind: String, _ userID: String) -> String { "\(kind).\(userID)" }

    /// A launch while signed out, before this build ever recorded an account:
    /// the unkeyed ids of an older build belonged to a session that has ended
    /// (older builds deleted them on sign-out), so nobody adopts them.
    public static func discardLegacy(store: any DeviceSecretStore = KeychainSecretStore(),
                                     service: String = defaultService) {
        for kind in ["link", "presence"] { store.delete(service: service, account: kind) }
    }

    static func id(userID: String, kind: String, store: any DeviceSecretStore, service: String) -> String {
        let account = account(kind, userID)
        if service == defaultService {
            // Unreadable now: this run uses a temporary id and writes nothing, so the id a Mac
            // approved (still under the old service) moves on a later launch.
            if store.adopt(from: legacyService, account: account, to: service) == .unreadable
                || store.adopt(from: legacyService, account: kind, to: service) == .unreadable {
                return UUID().uuidString.lowercased()
            }
        }
        store.adopt(service: service, from: kind, to: account)
        let stored: Data?
        do {
            stored = try store.read(service: service, account: account)
        } catch {
            // Unreadable now (say before the first unlock): never replace the stored
            // id, which the Mac approved; this run uses a temporary one.
            return UUID().uuidString.lowercased()
        }
        if let stored, let value = String(data: stored, encoding: .utf8), UUID(uuidString: value) != nil {
            return value
        }
        let value = UUID().uuidString.lowercased()
        try? store.write(Data(value.utf8), service: service, account: account)
        return value
    }
}
