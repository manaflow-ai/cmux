public import CmuxNextControl
import CmuxNextDaemon
import Foundation

/// Leo, 2026-11-14: "I tried to open up a link on the terminal on iOS. And a direct open link
/// one. It opened in Alma on Mac". A link a program in a terminal asks a browser for
/// (`browser.open_link`: the bundled `cmux-open-url` a cmux terminal's `BROWSER` names, and its
/// `open` / `xdg-open` shims) opens on the phone while a phone drives that terminal.
extension DaemonService {
    /// Asks the daemon to send `url` to the phone that drives terminal `terminal`
    /// (`offer-link-to-phone`): true when the phone got it and opens it, false when the Mac
    /// should open it as before (no phone drives the terminal, a page only the Mac reaches, an
    /// older daemon, no connection).
    public func offerLinkToPhone(terminal: String, url: String) async -> Bool {
        let offer = OfferLinkToPhoneRequest(terminalID: terminal, url: url)
        return await request(OfferLinkToPhoneRequest.command) { connection in
            try await connection.request(offer).offered
        } == true
    }
}

extension ControlMethod {
    /// A `mainActor` method that opens a terminal program's link (`params.url`, named by
    /// `params.terminal_id`), which first asks `daemon` whether a phone drives that terminal
    /// (``DaemonService/offerLinkToPhone(terminal:url:)``). Offered: the reply is
    /// `{target: "phone", opened_in: "phone"}` and `body` never runs, so the Mac opens nothing.
    /// Otherwise `body` runs as it always did. A request `body` refuses (a param outside
    /// `parameters`, no http or https URL) or one that forces `params.target` never asks.
    public static func offeringLinkToPhone(_ name: String, parameters: Set<String>, daemon: DaemonService,
                                           _ body: @escaping @MainActor @Sendable (ControlCall) throws -> ControlReply) -> ControlMethod {
        .mainActor(name) { [weak daemon] call in
            let params = call.params
            guard let daemon, params["target"] == nil, params.keys.allSatisfy(parameters.contains),
                  let terminal = params["terminal_id"]?.stringValue, !terminal.isEmpty,
                  let text = params["url"]?.stringValue, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
                return try body(call)
            }
            return .followUp {
                if await daemon.offerLinkToPhone(terminal: terminal, url: text) {
                    return .object(["target": .string("phone"), "opened_in": .string("phone")])
                }
                // `body`'s answer, from the main actor; `JSONValue` is not named here
                // (CmuxNextDaemon has one too).
                switch try await reply(call, body) {
                case .value(let value): return value
                case .followUp(let rest): return try await rest()
                }
            }
        }
    }

    /// `body`'s reply for a request no phone opened.
    @MainActor
    private static func reply(_ call: ControlCall, _ body: @MainActor @Sendable (ControlCall) throws -> ControlReply) throws -> ControlReply {
        try body(call)
    }
}
