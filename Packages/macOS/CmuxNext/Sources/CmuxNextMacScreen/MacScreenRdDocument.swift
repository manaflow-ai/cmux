import CmuxScreenKit
import CoreGraphics
import Foundation

/// The offer (viewer) and answer (host) of a Mac Screen session on cmux.rd/1
/// (plans/cmux-next/remote-desktop-mac-host.md section 7). They travel in the
/// device hub session's signaling as the offer's and answer's text, which the
/// Session DO forwards unread; `TicketSignaling` signs every `a=fingerprint:`
/// line with this device's key and checks the peer's against the key its
/// ticket names. The fingerprint line carries this side's cmux.rd session key,
/// so a session key is only ever accepted from the device the hub admitted.
/// The other lines are routes and wishes; the link authenticates every packet.
///
///     cmux.rd/1
///     a=fingerprint:cmux-rd-key <64 hex>
///     a=cmux-rd-candidate:host 192.168.1.4:51000     (repeated)
///     a=cmux-rd-display:1                             (offer: the display to show)
///     a=cmux-rd-display-id:69734208                   (offer: a run's display by CGDirectDisplayID; wins over the index)
///     a=cmux-rd-max-width:1920                        (offer: the quality wish)
///     a=cmux-rd-max-fps:120                           (offer)
///     a=cmux-rd-max-kbps:5000                         (offer: Customize's bitrate cap)
///     a=cmux-rd-cursor:0                              (offer: Customize's cursor; 1 or absent shows it)
///     a=cmux-rd-encode-profile:ultra                  (offer: remote.screenSharingProfile; absent: standard)
///     a=cmux-rd-displays:3342x2160,1920x1080          (answer: the host's displays)
///     a=cmux-rd-display-ids:1,69734208                (answer: the displays' CGDirectDisplayIDs, same order)
///     a=cmux-rd-current:0                             (answer: the display it streams)
nonisolated struct MacScreenRdDocument: Equatable, Sendable {
    static let header = "cmux.rd/1"
    static let keyPrefix = "cmux-rd-key "

    /// This side's session key (64 hex).
    var key: String
    var candidates: [String] = []
    var display: Int?
    /// The display to show by CGDirectDisplayID (a run's screen link); the host shows the main display when it is gone.
    var displayID: UInt32?
    var maxWidth: Int?
    var maxFps: Int?
    var maxKbps: Int?
    var cursor: Bool?
    /// The encode profile the viewer asks for (`ultra`); nil asks for the host's standard one.
    var encodeProfile: String?
    var displays: [CGSize] = []
    /// The host's displays' CGDirectDisplayIDs, in `displays` order (empty from an older host).
    var displayIDs: [UInt32] = []
    var currentDisplay: Int?

    /// Whether this answer says `id` is gone: it lists its display ids and `id` is not one. An older host lists
    /// none, so it says nothing either way.
    func lacksDisplay(_ id: UInt32) -> Bool { !displayIDs.isEmpty && !displayIDs.contains(id) }

    var text: String {
        var lines = [Self.header, "a=fingerprint:\(Self.keyPrefix)\(key)"]
        lines += candidates.map { "a=cmux-rd-candidate:\($0)" }
        if let display { lines.append("a=cmux-rd-display:\(display)") }
        if let displayID { lines.append("a=cmux-rd-display-id:\(displayID)") }
        if let maxWidth { lines.append("a=cmux-rd-max-width:\(maxWidth)") }
        if let maxFps { lines.append("a=cmux-rd-max-fps:\(maxFps)") }
        if let maxKbps { lines.append("a=cmux-rd-max-kbps:\(maxKbps)") }
        if let cursor { lines.append("a=cmux-rd-cursor:\(cursor ? 1 : 0)") }
        if let encodeProfile { lines.append("a=cmux-rd-encode-profile:\(encodeProfile)") }
        if !displays.isEmpty {
            lines.append("a=cmux-rd-displays:" + displays.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: ","))
        }
        if !displayIDs.isEmpty { lines.append("a=cmux-rd-display-ids:" + displayIDs.map(String.init).joined(separator: ",")) }
        if let currentDisplay { lines.append("a=cmux-rd-current:\(currentDisplay)") }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Parses a document; nil when it is not a cmux.rd one or has no valid key.
    init?(text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == Self.header else { return nil }
        var key: String?
        for line in lines.dropFirst() {
            guard line.hasPrefix("a="), let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 2) ..< colon])
            let value = String(line[line.index(after: colon)...])
            switch name {
            case "fingerprint" where value.hasPrefix(Self.keyPrefix):
                key = String(value.dropFirst(Self.keyPrefix.count))
            case "cmux-rd-candidate": candidates.append(value)
            case "cmux-rd-display": display = Int(value)
            case "cmux-rd-display-id": displayID = UInt32(value)
            case "cmux-rd-display-ids": displayIDs = value.split(separator: ",").compactMap { UInt32($0) }
            case "cmux-rd-max-width": maxWidth = Int(value)
            case "cmux-rd-max-fps": maxFps = Int(value)
            case "cmux-rd-max-kbps": maxKbps = Int(value)
            case "cmux-rd-cursor": cursor = value == "1" ? true : value == "0" ? false : nil
            case "cmux-rd-encode-profile": encodeProfile = value
            case "cmux-rd-current": currentDisplay = Int(value)
            case "cmux-rd-displays":
                displays = value.split(separator: ",").compactMap { size in
                    let parts = size.split(separator: "x").compactMap { Double($0) }
                    return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
                }
            default: continue
            }
        }
        guard let key, key.count == 64, key.allSatisfy(\.isHexDigit) else { return nil }
        self.key = key.lowercased()
    }

    init(key: String) {
        self.key = key
    }

    /// The Customize wishes of `preferences`: a bitrate cap when one is chosen, and a cursor
    /// line only when it is turned off, so a default offer reads as it always has.
    mutating func customize(_ preferences: ScreenPreferences) {
        maxKbps = preferences.maxKbps
        cursor = preferences.showCursorInStream ? nil : false
    }

    /// The stream size and rate a quality preset asks the host for (nil width: the display's own,
    /// fitted to 3840x2160). `refresh`: the viewer's display rate. `paneWidth`: the pane's screen
    /// area in pixels; Auto streams no wider (a Retina host's full size into a smaller pane costs
    /// capture, encode, network and decode time for pixels nobody sees), and at least 1280 wide.
    /// `maxFps`: Screen Sharing Frame Rate Limit (`remoteDesktop.maxFps`), a cap under the preset's rate.
    static func wish(_ quality: ScreenQuality, refresh: Int, paneWidth: Int? = nil, maxFps: Int? = nil) -> (maxWidth: Int?, maxFps: Int) {
        let refresh = max(1, min(max(30, min(refresh, 120)), maxFps ?? .max))
        return switch quality {
        case .auto: (paneWidth.map { max(1280, ($0 + 15) / 16 * 16) }, refresh)
        case .smooth: (1920, refresh)
        case .low: (1280, min(refresh, 60))
        case .medium: (1920, min(refresh, 60))
        case .high: (nil, min(refresh, 60))
        }
    }
}

/// The hub's ICE servers as the cmux.rd link takes them: STUN servers for this
/// side's public address, UDP TURN relays (`turn`) for a relayed path when no
/// direct one works, and the TCP and TLS (`turns:`) relays (`turn_stream`), the
/// only way through a network that blocks UDP. Mirrors `rd_doc::servers` in
/// cmux-hub-host: TCP before TLS, the ticket's order within each, and a bare
/// `turns:` host on 5349.
nonisolated struct MacScreenRdServers: Equatable, Sendable {
    /// How a relay is reached: `turn:` over UDP, `turn:..?transport=tcp`, or `turns:` (TLS).
    enum Transport: String, Encodable, Equatable, Sendable {
        case udp, tcp, tls
    }

    /// One relay. `transport` is left out for UDP, so a UDP relay reads as it always has.
    struct Turn: Encodable, Equatable, Sendable {
        var addr: String
        var username: String
        var password: String
        var transport: Transport = .udp

        private enum CodingKeys: String, CodingKey { case addr, username, password, transport }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(addr, forKey: .addr)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            if transport != .udp { try container.encode(transport, forKey: .transport) }
        }
    }

    var stun: [String] = []
    /// UDP relays, as every `cmux-rd` reads `turn`.
    var turn: [Turn] = []
    /// TCP relays, then TLS ones, as `cmux-rd` reads `turn_stream`.
    var turnStream: [Turn] = []

    init(_ servers: [ICEServerConfig]) {
        var relays: [Turn] = []
        for server in servers {
            for url in server.urls {
                let parts = url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
                let base = parts[0]
                let query = parts.count > 1 ? parts[1] : ""
                if base.hasPrefix("stun:") {
                    let address = Self.address(base.dropFirst("stun:".count))
                    if !address.isEmpty, !stun.contains(address) { stun.append(address) }
                    continue
                }
                let tls = base.hasPrefix("turns:")
                guard tls || base.hasPrefix("turn:") else { continue }
                let host = base.dropFirst(tls ? "turns:".count : "turn:".count)
                var transport: Transport = tls ? .tls : .udp
                guard let username = server.username, let password = server.credential else { continue }
                if transport == .udp,
                   query.split(separator: "&").contains(where: { $0.lowercased() == "transport=tcp" }) {
                    transport = .tcp
                }
                let address = transport == .tls && !host.contains(":") ? String(host) + ":5349" : Self.address(host)
                let relay = Turn(addr: address, username: username, password: password, transport: transport)
                if !host.isEmpty, !relays.contains(relay) { relays.append(relay) }
            }
        }
        // UDP first, then TCP, then TLS; the ticket's order within each (a stable partition).
        for kind in [Transport.udp, .tcp, .tls] {
            for relay in relays where relay.transport == kind {
                if kind == .udp { turn.append(relay) } else { turnStream.append(relay) }
            }
        }
    }

    /// `host` or `host:port` as `host:port` (3478 by default).
    private static func address(_ text: Substring) -> String {
        text.isEmpty ? "" : (text.contains(":") ? String(text) : String(text) + ":3478")
    }
}
