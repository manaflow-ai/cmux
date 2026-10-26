import Foundation

/// A page's alert, confirm or prompt as the shim sends it (JS_DIALOG, cmux_cef_shim.h; task
/// p01-process-063 of plans/cmux-next/chrome-parity/p01-process.md).
nonisolated struct CEFJSDialog: Equatable, Sendable {
    /// `cef_jsdialog_type_t`.
    nonisolated enum Kind: Int64, Sendable {
        case alert = 0
        case confirm = 1
        case prompt = 2
    }

    var kind: Kind
    var message: String
    /// A prompt's default text; "" for the others.
    var defaultText: String
    /// The URL of the frame that asks.
    var frameURL: String

    init(kind: Kind, message: String, defaultText: String = "", frameURL: String) {
        self.kind = kind
        self.message = message
        self.defaultText = defaultText
        self.frameURL = frameURL
    }

    /// JS_DIALOG's fields: `a` the kind, `s1` the message, `s2` the frame's URL, a newline, then the default
    /// text. A kind CEF does not have asks as an alert, so the page never waits for an answer that cannot come.
    init(wireKind: Int64, message: String, details: String) {
        let lines = details.shimFields(2)
        self.init(kind: Kind(rawValue: wireKind) ?? .alert, message: message, defaultText: lines[1], frameURL: lines[0])
    }

    /// The question the tab's prompt list holds (`BrowserPromptDialogs` shows it).
    var promptKind: BrowserPromptKind {
        switch kind {
        case .alert: .alert(message: message)
        case .confirm: .confirm(message: message)
        case .prompt: .textInput(message: message, defaultText: defaultText)
        }
    }

    /// The shim's answer to `response` (`cmux_shim_js_dialog_reply`): OK with a prompt's text, or Cancel.
    static func answer(to response: BrowserPromptResponse) -> (accept: Bool, text: String?) {
        switch response {
        case .text(let text): (true, text)
        case .accept, .allow, .allowOnce: (true, nil)
        case .deny, .cancel, .credentials: (false, nil)
        }
    }

    /// The origin the dialog's title names ("https://a.example says"), as a WebKit tab names it
    /// (`WebKitTab.displayOrigin`): scheme, host, and a port other than the scheme's default; a URL
    /// with no host (file:, data:) names its scheme only.
    var displayOrigin: String {
        guard let components = URLComponents(string: frameURL), let scheme = components.scheme else { return frameURL }
        guard let host = components.host, !host.isEmpty else { return "\(scheme)://" }
        let defaultPort = (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80)
        let port = components.port.map { defaultPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}

/// A server's or a proxy's request for a user name and password as the shim sends it (AUTH,
/// cmux_cef_shim.h; task p01-process-063).
nonisolated struct CEFAuthChallenge: Equatable, Sendable {
    var host: String
    var port: Int
    var isProxy: Bool
    /// The URL of the request's origin.
    var originURL: String
    /// Chromium's scheme name: "basic", "digest", "ntlm" or "negotiate".
    var scheme: String
    /// "" when the server sends none.
    var realm: String

    init(host: String, port: Int, isProxy: Bool, originURL: String, scheme: String, realm: String) {
        self.host = host
        self.port = port
        self.isProxy = isProxy
        self.originURL = originURL
        self.scheme = scheme
        self.realm = realm
    }

    /// AUTH's fields: `a` the port, `b` bit 0 for a proxy, `s1` the host, `s2` the origin URL, the scheme
    /// and the realm, one per line (the realm last, with whatever it holds).
    init(host: String, port: Int64, flags: Int64, details: String) {
        let lines = details.shimFields(3)
        self.init(host: host, port: Int(port), isProxy: flags & 1 != 0, originURL: lines[0], scheme: lines[1], realm: lines[2])
    }

    /// The space a WebKit tab's challenge would name, so a sign-in remembered in either engine answers
    /// the other (`BrowserHTTPCredentialKey`, `BrowserHTTPSignIn`).
    var protectionSpace: URLProtectionSpace {
        let realm = realm.isEmpty ? nil : realm
        if isProxy {
            return URLProtectionSpace(proxyHost: host, port: port, type: NSURLProtectionSpaceHTTPProxy, realm: realm,
                                      authenticationMethod: method)
        }
        let secure = URLComponents(string: originURL)?.scheme == "https"
        return URLProtectionSpace(host: host, port: port, protocol: secure ? NSURLProtectionSpaceHTTPS : NSURLProtectionSpaceHTTP,
                                  realm: realm, authenticationMethod: method)
    }

    /// Foundation's name of the scheme (net/http/http_auth_handler_factory.cc lists Chromium's).
    var method: String {
        switch scheme.lowercased() {
        case "basic": NSURLAuthenticationMethodHTTPBasic
        case "digest": NSURLAuthenticationMethodHTTPDigest
        case "ntlm": NSURLAuthenticationMethodNTLM
        case "negotiate": NSURLAuthenticationMethodNegotiate
        default: NSURLAuthenticationMethodDefault
        }
    }
}

private nonisolated extension String {
    /// The first `count - 1` lines of a shim string and the rest as the last field, "" for each one
    /// missing (CEFShim/src/page_dialog_state.h writes them). Split on the newline scalar, so a "\r\n"
    /// in the last field stays as it was.
    func shimFields(_ count: Int) -> [String] {
        let parts = unicodeScalars.split(separator: "\n", maxSplits: count - 1, omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        return parts + Array(repeating: "", count: max(0, count - parts.count))
    }
}
