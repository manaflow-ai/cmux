import Foundation

/// A Mac's invite for a new machine (Pair Another Machine…, the Mac's `PairingCode.Invite`): the
/// QR `https://cmux.com/pair?i=ABCDE12345`. A signed-in Mac mints it (`server.pair.invite`) and
/// the new machine redeems it with `cmux pair ABCDE-12345` (`POST /v1/pair/begin` with `invite`).
/// The phone is not that machine (it runs no cmux server and holds no install key), so it carries
/// the code: it shows the code and the one line to run, ready to copy or share. Confirming the new
/// machine stays on the Mac that made the invite.
///
/// Code rules (the Mac's and the backend's `normalizeInvite`): 10 Crockford base32 symbols,
/// shown `ABCDE-12345`, case insensitive, `O` read as `0`, `I`/`L` as `1`, dashes and spaces
/// dropped. The length tells it from the 8-symbol server code, which never reads as an invite.
public struct MachineInvite: Hashable, Sendable, Identifiable, CustomStringConvertible {
    public static let length = 10
    static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The canonical symbols (`ABCDE12345`). Single use and short-lived; never logged.
    public let code: String

    public var id: String { code }

    /// The code as people read it: `ABCDE-12345`.
    public var display: String { String(code.prefix(5)) + "-" + String(code.suffix(5)) }

    /// The one line the new machine runs (the Mac's `PairingCode.Invite.line`).
    public var line: String { "cmux pair \(display)" }

    /// The same for a Mac or Linux machine without cmux (the Mac's `PairingCode.Invite.installLine`).
    public var installLine: String { "curl -fsSL https://cmux.com/tui/install-static.sh | sh && ~/.cmux/bin/\(line)" }

    /// Never the code.
    public var description: String { "MachineInvite" }

    /// The invite `input` names once normalized; nil for any other length (a server code) or a
    /// symbol outside the alphabet.
    public init?(code input: String) {
        let code = Self.normalize(input)
        guard code.count == Self.length, code.allSatisfy(Self.alphabet.contains) else { return nil }
        self.code = code
    }

    /// The invite in the Mac's QR (`https://cmux.com/pair?i=…`, `www.` too); nil for any other
    /// link, the server code's `?c=`, or a malformed or missing code.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil, let host = components.host?.lowercased(), CmuxLink.webHosts.contains(host),
              components.path.split(separator: "/", omittingEmptySubsequences: true) == ["pair"] else { return nil }
        let items = components.queryItems ?? []
        let invites = items.filter { $0.name == "i" }
        guard invites.count == 1, !items.contains(where: { $0.name == "c" }), let value = invites[0].value else { return nil }
        self.init(code: value)
    }

    /// The invite in scanned text (the QR's link).
    public init?(text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    /// Canonical symbols of what a person typed or a link carried: uppercase, separators dropped,
    /// `O`->`0`, `I`/`L`->`1`. Symbols outside the alphabet stay, so ``init(code:)`` refuses them.
    public static func normalize(_ input: String) -> String {
        var out = ""
        for character in input.uppercased() {
            switch character {
            case "-", " ", "\u{2010}", "\u{2011}", "\u{2013}", "\u{2014}": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default: out.append(character)
            }
        }
        return out
    }
}
