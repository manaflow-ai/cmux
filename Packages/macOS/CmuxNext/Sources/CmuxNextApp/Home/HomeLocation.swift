import Foundation

/// Where Home loads mux from: the local server by default (mux/local, port
/// 47820). `CMUX_NEXT_MUX_URL` points elsewhere, e.g. the staging Worker.
enum HomeLocation {
    static let defaultURL = URL(string: "http://127.0.0.1:47820")!

    /// Shown when the local server does not answer. Not localized: a command.
    static let startCommand = "cd mux/cli && bun src/main.ts install"

    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        override(environment: environment) ?? defaultURL
    }

    /// `CMUX_NEXT_MUX_URL`: Home loads it and starts no local server.
    static func override(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let url = environment["CMUX_NEXT_MUX_URL"].flatMap(URL.init(string:)),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }
}

enum HomeStrings {
    static var title: String { String(localized: "home.title", defaultValue: "Home", bundle: .module) }
    static var unavailableTitle: String {
        String(localized: "home.unavailable.title", defaultValue: "mux is not running", bundle: .module)
    }
    static var unavailableDetail: String {
        String(localized: "home.unavailable.detail", defaultValue: "cmux starts the local mux server with the mux command. Install it from your cmux checkout, then retry:", bundle: .module)
    }
    static var retry: String { String(localized: "home.unavailable.retry", defaultValue: "Retry", bundle: .module) }
}
