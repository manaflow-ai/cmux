import Foundation

/// One status line `cmux-mobile-host` writes on stdout when the app supervises it
/// (`CMUX_MOBILE_CONTROL=stdio`, cmux-next-ios/rust/crates/cmux-mobile-host/src/control.rs).
public enum MobileHostEvent: Sendable, Equatable {
    /// Registering the Mac and opening the signaling socket.
    case connecting
    /// Registered and holding the signaling socket: phones can dial.
    case online(deviceID: String, teamID: String)
    /// The last attempt failed or the socket closed; hostd retries after the delay.
    case waiting(reason: String, retryInSeconds: Int)
    /// The access token is missing, about to expire, or was refused.
    case needToken
    /// acpmux is unknown or refused a connection (it restarted elsewhere).
    case needAcpmux
    /// Fresh app-server carrier facts for one bounded Rust request.
    case needCloudLinks(request: UInt64)
    /// A phone's link is up.
    case phoneUp(MobileHostPhoneLink)
    /// A phone's link moved to another path (`direct`, `relay`, `turn`).
    case phonePath(sessionID: String, path: String)
    /// The WebRTC media session beside a phone's WireGuard link came up over
    /// `mediaPath` (`direct`, `turn`), or went away (nil).
    case phoneMedia(sessionID: String, mediaPath: String?)
    /// A phone's link ended.
    case phoneDown(sessionID: String, reason: String)
    /// A phone proved keys this Mac has not approved: ask the user (``MobileHostPairedDevices``).
    case pairRequest(MobileHostPairRequest)
    /// A paired phone signed out and asks this Mac to forget it.
    case unpaired(phoneDeviceID: String)
    /// A phone opened a streamed browser tab: start a browser host for `tab`
    /// on `url` and answer `request` (``MobileHostLaunch/browserLine(request:port:secret:)``).
    case needBrowser(request: UInt64, tab: String, url: String)
    /// hostd no longer needs the browser host of `tab`.
    case browserStop(tab: String)
    /// A phone opened a streamed simulator surface: start the source of phone
    /// tab `tab` and answer `request` (``MobileHostLaunch/surfaceLine(request:port:secret:)``).
    case needSurface(request: UInt64, tab: String)
    /// hostd no longer needs the surface source of `tab`.
    case surfaceStop(tab: String)
    /// The owner removed this Mac from the account's devices; hostd exits and must not
    /// be restarted until the person allows iPhone connections again.
    case removed

    /// Parses one stdout line; nil for anything that is not a known event.
    public init?(line: some StringProtocol) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = try? decoder.decode(Wire.self, from: Data(String(line).utf8)) else { return nil }
        switch wire.type {
        case "connecting":
            self = .connecting
        case "online":
            guard let device = wire.deviceId, let team = wire.teamId else { return nil }
            self = .online(deviceID: device, teamID: team)
        case "waiting":
            self = .waiting(reason: wire.reason ?? "", retryInSeconds: wire.retryInSeconds ?? 0)
        case "need_token":
            self = .needToken
        case "need_acpmux":
            self = .needAcpmux
        case "need_cloud_links":
            guard let request = wire.request else { return nil }
            self = .needCloudLinks(request: request)
        case "phone_up":
            guard let session = wire.sessionId, let phone = wire.phoneDeviceId else { return nil }
            self = .phoneUp(MobileHostPhoneLink(sessionID: session, phoneDeviceID: phone,
                                         transport: wire.transport ?? "", path: wire.path ?? ""))
        case "phone_path":
            guard let session = wire.sessionId, let path = wire.path else { return nil }
            self = .phonePath(sessionID: session, path: path)
        case "phone_media":
            guard let session = wire.sessionId, let media = wire.mediaPath else { return nil }
            self = .phoneMedia(sessionID: session, mediaPath: media == "none" ? nil : media)
        case "phone_down":
            guard let session = wire.sessionId else { return nil }
            self = .phoneDown(sessionID: session, reason: wire.reason ?? "")
        case "pair_request":
            guard let phone = wire.phoneDeviceId, let identity = wire.identityKey, let approval = wire.approvalKey else { return nil }
            let registered = wire.registeredAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            self = .pairRequest(MobileHostPairRequest(phoneDeviceID: phone, name: wire.name ?? "", identityKey: identity,
                                               approvalKey: approval, registeredAt: registered, pairToken: wire.pairToken))
        case "unpaired":
            guard let phone = wire.phoneDeviceId else { return nil }
            self = .unpaired(phoneDeviceID: phone)
        case "need_browser":
            guard let request = wire.request, let tab = wire.tab else { return nil }
            self = .needBrowser(request: request, tab: tab, url: wire.url ?? "about:blank")
        case "browser_stop":
            guard let tab = wire.tab else { return nil }
            self = .browserStop(tab: tab)
        case "need_surface":
            guard let request = wire.request, let tab = wire.tab else { return nil }
            self = .needSurface(request: request, tab: tab)
        case "surface_stop":
            guard let tab = wire.tab else { return nil }
            self = .surfaceStop(tab: tab)
        case "removed":
            self = .removed
        default:
            return nil
        }
    }

    /// The line's fields (`control.rs` `Event`; snake case on the wire).
    private struct Wire: Decodable {
        var type: String
        var deviceId: String?
        var teamId: String?
        var reason: String?
        var retryInSeconds: Int?
        var sessionId: String?
        var phoneDeviceId: String?
        var transport: String?
        var path: String?
        var mediaPath: String?
        var name: String?
        var identityKey: String?
        var approvalKey: String?
        var registeredAtMs: Int64?
        var pairToken: String?
        var request: UInt64?
        var tab: String?
        var url: String?
    }
}
