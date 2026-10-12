import AppKit
import CmuxNativeLink
import CmuxNextPages
import CmuxNextSettings
import CoreImage
import Foundation

/// Settings > iPhone in the React Settings page: the host lists' `phone` (every text localized
/// here, as Accounts does) and its gestures (`cmux.settings.phone.run`).
extension NativePhoneHost {
    var pageJSON: JSONValue {
        var object: [String: JSONValue] = [
            "enabled": .bool(enabled),
            "status": .string(statusText),
            "status_kind": .string(statusKind),
            "host_name": hostName.map(JSONValue.string) ?? .null,
            "daemon": .bool(hasDaemon),
            "peers": .array(peers.map { peer in
                ["id": .string(peer.id), "path": .string(PhoneStrings.path(peer.path))]
            }),
            "pairing_busy": .bool(pairingBusy),
            "error": lastError.map(JSONValue.string) ?? .null,
            "can_reset": .bool(hostID != nil),
            "strings": PhoneStrings.page,
        ]
        if let pairing {
            object["pairing"] = [
                "code": .string(pairing.code),
                "url": .string(pairing.url),
                "qr": NativePhoneQRCode.dataURL(pairing.url).map(JSONValue.string) ?? .null,
                "expires_at": .number((pairing.expiresAt.timeIntervalSince1970 * 1000).rounded()),
            ]
        } else {
            object["pairing"] = .null
        }
        return .object(object)
    }

    private var statusText: String {
        switch phase {
        case .off: PhoneStrings.statusOff
        case .registering: PhoneStrings.statusRegistering
        case .connecting: PhoneStrings.statusConnecting
        case .listening: hasDaemon ? PhoneStrings.statusListening : PhoneStrings.statusNoDaemon
        case .reconnecting: PhoneStrings.statusReconnecting
        case .failed(let reason): String(format: PhoneStrings.statusFailed, reason)
        }
    }

    private var statusKind: String {
        switch phase {
        case .off: "quiet"
        case .listening: hasDaemon ? "success" : "attention"
        case .registering, .connecting, .reconnecting: "neutral"
        case .failed: "attention"
        }
    }

    /// One gesture of the iPhone card. Turning access on and showing a pairing code need the
    /// person's own click or key press in the page (`userGesture`), never a script.
    func runPage(_ params: JSONValue, userGesture: Bool) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        switch action {
        case "enable", "pair", "reset":
            guard userGesture else { throw PageError(code: "cmux.settings.user_only", message: "only the person turns on iPhone access") }
        default:
            break
        }
        switch action {
        case "enable": setEnabled(true)
        case "disable": setEnabled(false)
        case "pair": await pair()
        case "endPairing": endPairing()
        case "reset": resetRegistration()
        default: throw PageError.invalidParams("unknown phone action \(action)")
        }
        return .object([:])
    }
}

/// The pairing QR code (CoreImage's generator), as a PNG data URL the page draws in an `<img>`.
enum NativePhoneQRCode {
    /// Pixels per module: the page shows it at 1/4 for a sharp code on Retina screens.
    static let scale: CGFloat = 8
    private static var cache: (text: String, url: String)?

    static func dataURL(_ text: String) -> String? {
        if let cache, cache.text == text { return cache.url }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSBitmapImageRep(ciImage: output)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        cache = (text, url)
        return url
    }
}

/// Settings > iPhone texts (Resources/Phone.xcstrings).
enum PhoneStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Phone", bundle: .module)
    }

    static var statusOff: String { text("phone.status.off", "Off") }
    static var statusRegistering: String { text("phone.status.registering", "Registering this Mac…") }
    static var statusConnecting: String { text("phone.status.connecting", "Connecting…") }
    static var statusListening: String { text("phone.status.listening", "Ready for your iPhone") }
    static var statusNoDaemon: String { text("phone.status.noDaemon", "Waiting for this Mac's terminals") }
    static var statusReconnecting: String { text("phone.status.reconnecting", "Reconnecting…") }
    static var statusFailed: String { text("phone.status.failed", "Could not connect: %@") }

    static func path(_ path: LinkPath) -> String {
        switch path {
        case .direct: text("phone.path.direct", "Direct")
        case .relay: text("phone.path.relay", "Relay")
        case .unknown: text("phone.path.unknown", "Connected")
        }
    }

    /// The card's fixed texts; `expires` has one `%@` for the time left (`9:41`).
    static var page: JSONValue {
        [
            "title": .string(text("phone.title", "iPhone")),
            "allow": .string(text("phone.allow", "Allow the cmux iPhone app to connect")),
            "allow_help": .string(text("phone.allow.help",
                                       "Your iPhone reaches this Mac's terminals over an encrypted link, direct or relayed.")),
            "status": .string(text("phone.status", "Status")),
            "registered_as": .string(text("phone.registeredAs", "This Mac is registered as %@.")),
            "pair": .string(text("phone.pair", "Pair iPhone")),
            "pair_help": .string(text("phone.pair.help", "Scan the code with the cmux iPhone app, or type it in.")),
            "refresh": .string(text("phone.pair.refresh", "New Code")),
            "done": .string(text("phone.pair.done", "Done")),
            "expires": .string(text("phone.pair.expires", "Expires in %@")),
            "expired": .string(text("phone.pair.expired", "This code expired.")),
            "phones": .string(text("phone.phones", "Connected iPhones")),
            "no_phones": .string(text("phone.phones.none", "No iPhone is connected.")),
            "reset": .string(text("phone.reset", "Register Again")),
            "reset_help": .string(text("phone.reset.help", "Forgets this Mac's registration. Paired iPhones pair again.")),
        ]
    }
}
