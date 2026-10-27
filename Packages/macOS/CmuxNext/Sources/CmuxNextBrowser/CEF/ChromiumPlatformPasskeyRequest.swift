import CmuxNextCompat
import Foundation

/// One iCloud Keychain request of the fork (include/cef_cmux.h, "Request JSON"), decoded. Only the fields
/// cmux applies through public AuthenticationServices calls are kept; see ``parse(_:operation:)``.
nonisolated struct ChromiumPlatformPasskeyRequest: Sendable, Equatable {
    /// The account a create makes the passkey for.
    struct User: Sendable, Equatable {
        var id: Data
        var name: String
        var displayName: String?
    }

    var operation: ChromiumPlatformPasskeyOperation
    var rpID: String
    /// Chromium's client data, exactly the bytes the page receives (empty for a list).
    var clientDataJSON = Data()
    /// The SHA-256 of ``clientDataJSON`` as Chromium computed it.
    var clientDataHash = Data()
    /// `discouraged`, `preferred` or `required`.
    var userVerification = "preferred"
    /// Ask for the passkey listing permission first, then run the ceremony whatever the answer.
    var requestPermission = false
    var user: User?
    /// COSE algorithm ids of a create.
    var algorithms: [Int] = []
    var excludeCredentials: [Data] = []
    var allowCredentials: [Data] = []
    /// Always false from the fork: phones stay in Chromium's hybrid flow (passkeys.md 3.9.1).
    var showsHybridTransport = false
    /// A create that must store a large blob.
    var requiresLargeBlob = false

    /// The ES256 COSE id, the one algorithm iCloud Keychain passkeys use.
    static let es256 = -7

    /// The request of `json`, nil when it is not one: no rp id, a byte string that is not base64url, or a
    /// create or get without client data. PRF inputs and a preferred or read/write large blob are not kept:
    /// cmux runs the ceremony without them, as Chrome does on a macOS without those calls
    /// (device/fido/mac/icloud_keychain_sys.mm, the `@available` blocks), and the reply then reports none.
    static func parse(_ json: String, operation: ChromiumPlatformPasskeyOperation) -> ChromiumPlatformPasskeyRequest? {
        guard let object = (try? JSONSerialization.blockingJSONObject(with: Data(json.utf8))) as? [String: Any],
              let rpID = object["rp_id"] as? String, !rpID.isEmpty else { return nil }
        var request = ChromiumPlatformPasskeyRequest(operation: operation, rpID: rpID.lowercased())
        guard operation != .list else { return request }
        guard let clientData = (object["client_data_json"] as? String).map({ Data($0.utf8) }), !clientData.isEmpty,
              let hash = (object["client_data_hash"] as? String).flatMap(Self.bytes) else { return nil }
        request.clientDataJSON = clientData
        request.clientDataHash = hash
        request.userVerification = object["user_verification"] as? String ?? "preferred"
        request.requestPermission = object["request_permission"] as? Bool ?? false
        switch operation {
        case .create:
            guard let user = object["user"] as? [String: Any], let id = (user["id"] as? String).flatMap(Self.bytes) else { return nil }
            request.user = User(id: id, name: user["name"] as? String ?? "", displayName: user["display_name"] as? String)
            request.algorithms = (object["algorithms"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            guard let excluded = Self.descriptorIDs(object["exclude_credentials"]) else { return nil }
            request.excludeCredentials = excluded
            request.requiresLargeBlob = object["large_blob"] as? String == "required"
        case .get:
            let allowed = (object["allow_credentials"] as? [Any]) ?? []
            let ids = allowed.compactMap { ($0 as? String).flatMap(Self.bytes) }
            guard ids.count == allowed.count else { return nil }
            request.allowCredentials = ids
            request.showsHybridTransport = object["show_hybrid_transport"] as? Bool ?? false
        case .list:
            break
        }
        return request
    }

    /// The `id`s of `[{"id", "transports"}]`, nil when one is not base64url.
    private static func descriptorIDs(_ value: Any?) -> [Data]? {
        let rows = (value as? [Any]) ?? []
        let ids = rows.compactMap { (($0 as? [String: Any])?["id"] as? String).flatMap(Self.bytes) }
        return ids.count == rows.count ? ids : nil
    }

    /// Unpadded base64url (the fork's byte strings), nil for anything else.
    static func bytes(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        return Data(base64Encoded: base64)
    }

    /// Unpadded base64url of `data`.
    static func text(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The members of Chromium's client data JSON (content/browser/webauth/client_data_json.cc,
/// `BuildClientDataJson`) that the origin checks and the system's own client data need.
nonisolated struct ChromiumClientData: Sendable, Equatable {
    /// `webauthn.create` or `webauthn.get`.
    var type: String
    var challenge: Data
    var origin: String
    var crossOrigin: Bool
    var topOrigin: String?
    /// Members other than these five: `other_keys_can_be_added_here`, which Chromium adds to one request in five so
    /// relying parties do not compare client data against a template (components/webauthn/core/browser/
    /// client_data_json.cc), and payment members. The system cannot build such client data.
    var hasOtherMembers: Bool

    private static let members: Set<String> = ["type", "challenge", "origin", "crossOrigin", "topOrigin"]

    /// The client data of `json`, nil when a member is missing or of the wrong type.
    init?(_ json: Data) {
        guard let object = (try? JSONSerialization.blockingJSONObject(with: json)) as? [String: Any],
              let type = object["type"] as? String, let challenge = (object["challenge"] as? String).flatMap(ChromiumPlatformPasskeyRequest.bytes),
              let origin = object["origin"] as? String else { return nil }
        (self.type, self.challenge, self.origin) = (type, challenge, origin)
        crossOrigin = object["crossOrigin"] as? Bool ?? false
        topOrigin = object["topOrigin"] as? String
        hasOtherMembers = !Set(object.keys).isSubset(of: Self.members)
    }
}
