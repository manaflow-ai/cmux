import Foundation

/// Where Home loads mux from: the local server by default (mux/local, port
/// 47820). `CMUX_NEXT_MUX_URL` points elsewhere, e.g. the staging Worker.
enum HomeLocation {
    static let defaultURL = URL(string: "http://127.0.0.1:47820")!
    /// Shown when the local server does not answer. Not localized: a command.
    static let startCommand = "cd mux && vp run local"

    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let override = environment["CMUX_NEXT_MUX_URL"].flatMap(URL.init(string:)),
              override.scheme == "https" || override.scheme == "http" else { return defaultURL }
        return override
    }
}

enum HomeStrings {
    static var title: String { String(localized: "home.title", defaultValue: "Home", bundle: .module) }
    static var unavailableTitle: String {
        String(localized: "home.unavailable.title", defaultValue: "mux is not running", bundle: .module)
    }
    static var unavailableDetail: String {
        String(localized: "home.unavailable.detail", defaultValue: "Start the local mux server in your cmux checkout, then retry:", bundle: .module)
    }
    static var retry: String { String(localized: "home.unavailable.retry", defaultValue: "Retry", bundle: .module) }
}
