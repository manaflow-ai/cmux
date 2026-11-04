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
///     a=cmux-rd-max-width:1920                        (offer: the quality wish)
///     a=cmux-rd-max-fps:120                           (offer)
///     a=cmux-rd-displays:3342x2160,1920x1080          (answer: the host's displays)
///     a=cmux-rd-current:0                             (answer: the display it streams)
nonisolated struct MacScreenRdDocument: Equatable, Sendable {
    static let header = "cmux.rd/1"
    static let keyPrefix = "cmux-rd-key "

    /// This side's session key (64 hex).
    var key: String
    var candidates: [String] = []
    var display: Int?
    var maxWidth: Int?
    var maxFps: Int?
    var displays: [CGSize] = []
    var currentDisplay: Int?

    var text: String {
        var lines = [Self.header, "a=fingerprint:\(Self.keyPrefix)\(key)"]
        lines += candidates.map { "a=cmux-rd-candidate:\($0)" }
        if let display { lines.append("a=cmux-rd-display:\(display)") }
        if let maxWidth { lines.append("a=cmux-rd-max-width:\(maxWidth)") }
        if let maxFps { lines.append("a=cmux-rd-max-fps:\(maxFps)") }
        if !displays.isEmpty {
            lines.append("a=cmux-rd-displays:" + displays.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: ","))
        }
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
            case "cmux-rd-max-width": maxWidth = Int(value)
            case "cmux-rd-max-fps": maxFps = Int(value)
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

    /// The stream size and rate a quality preset asks the host for (nil width: the display's own,
    /// fitted to 3840x2160). `refresh`: the viewer's display rate.
    static func wish(_ quality: ScreenQuality, refresh: Int) -> (maxWidth: Int?, maxFps: Int) {
        let refresh = max(30, min(refresh, 120))
        return switch quality {
        case .auto: (nil, refresh)
        case .smooth: (1920, refresh)
        case .low: (1280, min(refresh, 60))
        case .medium: (1920, min(refresh, 60))
        case .high: (nil, min(refresh, 60))
        }
    }
}

/// The hub's ICE servers as the cmux.rd link takes them: STUN servers for this
/// side's public address, and TURN relays (UDP) with their credentials for a
/// relayed path when no direct one works. `turns:` and TCP-only relays are not
/// carriers of the link yet and are left out.
nonisolated struct MacScreenRdServers: Equatable, Sendable {
    struct Turn: Encodable, Equatable, Sendable {
        var addr: String
        var username: String
        var password: String
    }

    var stun: [String] = []
    var turn: [Turn] = []

    init(_ servers: [ICEServerConfig]) {
        for server in servers {
            for url in server.urls {
                let parts = url.split(separator: "?", maxSplits: 1)
                let query = parts.count > 1 ? String(parts[1]) : ""
                if url.hasPrefix("stun:") {
                    let address = Self.address(parts[0].dropFirst("stun:".count))
                    if !address.isEmpty, !stun.contains(address) { stun.append(address) }
                } else if url.hasPrefix("turn:"), !query.contains("transport=tcp"),
                          let username = server.username, let password = server.credential {
                    let address = Self.address(parts[0].dropFirst("turn:".count))
                    let relay = Turn(addr: address, username: username, password: password)
                    if !address.isEmpty, !turn.contains(relay) { turn.append(relay) }
                }
            }
        }
    }

    /// `host` or `host:port` as `host:port` (3478 by default).
    private static func address(_ text: Substring) -> String {
        text.isEmpty ? "" : (text.contains(":") ? String(text) : String(text) + ":3478")
    }
}
