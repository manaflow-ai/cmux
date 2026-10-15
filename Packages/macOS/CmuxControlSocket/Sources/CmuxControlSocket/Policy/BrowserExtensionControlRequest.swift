public import Foundation

/// One `cmux browser <surface> extension ...` invocation as a v2 socket call.
///
/// The CLI parses with ``init(verb:arguments:currentDirectory:)``; the app
/// handler waits at most ``consentSeconds`` for the person to answer a
/// consent sheet, and the CLI's response timeout covers that window plus
/// ``clientSlackSeconds`` so the two cannot drift apart.
public struct BrowserExtensionControlRequest: Equatable, Sendable {
    /// Why a command line could not be mapped to a request.
    public enum ParseError: Error, Equatable, Sendable {
        /// The verb takes a different number of arguments.
        case wrongArgumentCount
        /// `move` needs an index of 0 or more.
        case invalidIndex
        /// The verb is not an extension command.
        case unknownVerb(String)
    }

    /// How long the app waits for the person to answer a consent sheet.
    public static let consentSeconds: TimeInterval = 120
    /// Slack the client adds on top of the app's window.
    public static let clientSlackSeconds: TimeInterval = 10
    /// The response timeout of calls that never wait for the person.
    public static let quickSeconds: TimeInterval = 20

    /// The v2 method.
    public var method: String
    /// The method's parameters (string-valued), without `surface_id`.
    public var params: [String: String]
    /// The client's response timeout.
    public var responseTimeout: TimeInterval

    /// Creates a request directly.
    public init(method: String, params: [String: String], responseTimeout: TimeInterval) {
        self.method = method
        self.params = params
        self.responseTimeout = responseTimeout
    }

    /// Maps a verb and its arguments.
    ///
    /// - Parameters:
    ///   - verb: The subcommand, case-insensitive (`list` when empty).
    ///   - arguments: The arguments after the verb.
    ///   - currentDirectory: Resolves a relative `load` path.
    /// - Throws: ``ParseError``.
    public init(verb: String, arguments: [String], currentDirectory: String) throws(ParseError) {
        let consent = Self.consentSeconds + Self.clientSlackSeconds
        let verb = verb.isEmpty ? "list" : verb.lowercased()
        func needs(_ count: Int) throws(ParseError) {
            guard arguments.count == count else { throw .wrongArgumentCount }
        }
        switch verb {
        case "list", "ls":
            try needs(0)
            self.init(method: "browser.extension.list", params: [:], responseTimeout: Self.quickSeconds)
        case "load", "load-unpacked":
            try needs(1)
            let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
            let path = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath, relativeTo: base)
                .standardizedFileURL.path
            if path.lowercased().hasSuffix(".crx") {
                self.init(method: "browser.extension.install_crx", params: ["path": path], responseTimeout: Self.quickSeconds)
            } else {
                self.init(method: "browser.extension.load", params: ["path": path], responseTimeout: consent)
            }
        case "enable", "run", "reload":
            try needs(1)
            self.init(method: "browser.extension.\(verb)", params: ["extension": arguments[0]], responseTimeout: consent)
        case "disable", "remove", "pin", "unpin", "options":
            try needs(1)
            self.init(method: "browser.extension.\(verb)", params: ["extension": arguments[0]], responseTimeout: Self.quickSeconds)
        case "move":
            try needs(2)
            guard let index = Int(arguments[1]), index >= 0 else { throw .invalidIndex }
            self.init(method: "browser.extension.move", params: ["extension": arguments[0], "index": String(index)],
                      responseTimeout: Self.quickSeconds)
        case "command":
            try needs(2)
            self.init(method: "browser.extension.command", params: ["extension": arguments[0], "command": arguments[1]],
                      responseTimeout: consent)
        case "webstore", "manage":
            try needs(0)
            self.init(method: "browser.extension.open_page", params: ["page": verb], responseTimeout: Self.quickSeconds)
        default:
            throw .unknownVerb(verb)
        }
    }
}
