import Foundation

/// The `502` page a plain-HTTP localhost request gets when its tunnel does
/// not open. It names the machine, so a failure never looks like this Mac's
/// localhost. (`CONNECT` failures cannot carry a page: Chromium shows its own
/// tunnel error for them.)
struct ProxyErrorPage {
    var host: String
    var port: UInt16
    var machine: String
    var failure: LoopbackTunnelFailure

    var title: String { Strings.errorTitle(target: "\(displayHost):\(port)", machine: machine) }

    var detail: String {
        switch failure {
        case .refused: Strings.errorRefused(machine)
        case .unsupported: Strings.errorUnsupported(machine)
        case .disabled: Strings.errorDisabled(machine)
        case .portNotAllowed: Strings.errorPortNotAllowed(machine)
        case .unavailable: Strings.errorUnavailable(machine)
        case .other: Strings.errorOther(machine)
        }
    }

    private var displayHost: String { host.contains(":") ? "[\(host)]" : host }

    func response() -> Data {
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">\
        <title>\(Self.escape(title))</title><style>body{font:14px -apple-system,system-ui,sans-serif;\
        max-width:36em;margin:18vh auto;padding:0 24px;color:#555}@media(prefers-color-scheme:dark)\
        {body{color:#aaa;background:#1e1e1e}}h1{font-size:18px;font-weight:600;color:inherit}\
        p.note{font-size:12px;opacity:.7}</style></head><body><h1>\(Self.escape(title))</h1>\
        <p>\(Self.escape(detail))</p><p class="note">\(Self.escape(Strings.errorFooter(machine)))</p></body></html>
        """
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
