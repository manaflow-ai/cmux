import Foundation

/// One WebAuthn request a Chromium page sent to cmux (fork API 33, `cmux_shim_webauthn_request_fn`):
/// a page nobody sees, or a tab in `CMUX_WEBAUTHN_MODE_DELEGATE`. Chromium already checked the
/// origin, the RP ID against it, TLS and the frame's permissions policy; everything else here is
/// page data (`options`), read only to build the system request.
nonisolated struct CEFWebAuthnRequest: Equatable, Sendable {
    enum Kind: Int, Sendable { case create = 0, get = 1 }

    /// `CMUX_WEBAUTHN_MEDIATION_*`.
    enum Mediation: Int, Sendable { case modal = 0, conditional = 1, immediate = 2, ambient = 3 }

    /// `CMUX_WEBAUTHN_MODE_DELEGATE`: cmux set the tab to send every request here.
    static let delegateTabMode = 2

    let id: Int32
    let browserID: Int32
    let kind: Kind
    let mediation: Mediation
    /// The requesting frame's origin: the clientData origin, shown to the person.
    let origin: String
    let topOrigin: String
    let crossOrigin: Bool
    let rpID: String
    let userActivation: Bool
    let tabMode: Int
    /// Nobody sees the page window (a detached or remote-presentation page).
    let detached: Bool
    let mainFrame: Bool
    let options: Options

    /// Decodes the shim's JSON; nil for a malformed or unknown request (answered NotAllowedError).
    init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let id = object["request_id"] as? Int, id > 0,
              let kind = (object["type"] as? Int).flatMap(Kind.init(rawValue:)),
              let origin = object["origin"] as? String, !origin.isEmpty,
              let rpID = object["rp_id"] as? String, !rpID.isEmpty else { return nil }
        self.id = Int32(truncatingIfNeeded: id)
        self.kind = kind
        browserID = Int32(truncatingIfNeeded: object["browser_id"] as? Int ?? 0)
        mediation = (object["mediation"] as? Int).flatMap(Mediation.init(rawValue:)) ?? .modal
        self.origin = origin
        topOrigin = object["top_origin"] as? String ?? origin
        crossOrigin = object["cross_origin"] as? Bool ?? false
        self.rpID = rpID
        userActivation = object["user_activation"] as? Bool ?? false
        tabMode = object["tab_mode"] as? Int ?? 0
        detached = object["detached"] as? Bool ?? false
        mainFrame = object["main_frame"] as? Bool ?? true
        options = Options(json: object["options_json"] as? String ?? "")
    }

    /// The parts of PublicKeyCredentialCreationOptionsJSON / RequestOptionsJSON the system request takes.
    struct Options: Equatable, Sendable {
        struct Descriptor: Equatable, Sendable {
            let id: Data
            /// "usb", "nfc", "ble", "hybrid", "internal"; empty when the page named none.
            let transports: [String]
        }

        var challenge: Data?
        var userID: Data?
        var userName = ""
        var userDisplayName = ""
        /// COSE algorithm identifiers in the page's order (create).
        var algorithms: [Int] = []
        /// excludeCredentials (create) or allowCredentials (get).
        var credentials: [Descriptor] = []
        /// "required", "preferred", "discouraged".
        var userVerification = "preferred"
        var residentKey = "preferred"
        /// "platform", "cross-platform" or "" (any).
        var attachment = ""
        var attestation = "none"
        /// The FIDO U2F appid extension (get).
        var appID: String?
        /// The page asked for the credProps extension (create).
        var credProps = false

        init(json: String) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
            challenge = (object["challenge"] as? String).flatMap(Data.init(base64URL:))
            if let user = object["user"] as? [String: Any] {
                userID = (user["id"] as? String).flatMap(Data.init(base64URL:))
                userName = user["name"] as? String ?? ""
                userDisplayName = user["displayName"] as? String ?? ""
            }
            algorithms = (object["pubKeyCredParams"] as? [[String: Any]] ?? []).compactMap { $0["alg"] as? Int }
            let list = object["excludeCredentials"] ?? object["allowCredentials"]
            credentials = (list as? [[String: Any]] ?? []).compactMap { item in
                guard let id = (item["id"] as? String).flatMap(Data.init(base64URL:)) else { return nil }
                return Descriptor(id: id, transports: item["transports"] as? [String] ?? [])
            }
            if let selection = object["authenticatorSelection"] as? [String: Any] {
                userVerification = selection["userVerification"] as? String ?? userVerification
                let required = selection["requireResidentKey"] as? Bool == true
                residentKey = selection["residentKey"] as? String ?? (required ? "required" : residentKey)
                attachment = selection["authenticatorAttachment"] as? String ?? ""
            } else if let verification = object["userVerification"] as? String {
                userVerification = verification
            }
            attestation = object["attestation"] as? String ?? attestation
            if let extensions = object["extensions"] as? [String: Any] {
                appID = extensions["appid"] as? String
                credProps = extensions["credProps"] as? Bool == true
            }
        }
    }
}

extension Data {
    /// base64url without padding, as WebAuthn JSON writes binary fields.
    nonisolated init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    nonisolated var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
