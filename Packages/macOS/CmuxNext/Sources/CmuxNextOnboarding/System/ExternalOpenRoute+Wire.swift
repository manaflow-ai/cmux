import Foundation

/// What the Rust external-open rules read and answer (`onboarding_steps_external_open`,
/// `_sign_in_callback`, `_ssh_target`, `_trust_key`): the app's types as cmux-window-rules
/// `external_open` names them. No rule lives here.
extension ExternalOpenRouter {
    /// A URL's parts as Foundation read them (Rust `Link`).
    nonisolated struct Link: Encodable, Sendable {
        var absolute: String, scheme: String?, host: String?, user: String?
        var password: Bool, query: Bool, fragment: Bool, port: Int?
        var pathEncoded: String, path: String, pathComponents: [String], authCallback: Bool

        init(_ url: URL, authCallback: Bool) {
            absolute = url.absoluteString
            scheme = url.scheme
            host = url.host(percentEncoded: false)
            user = url.user(percentEncoded: false)
            password = url.password(percentEncoded: true) != nil
            query = url.query(percentEncoded: true) != nil
            fragment = url.fragment(percentEncoded: true) != nil
            port = url.port
            pathEncoded = url.path(percentEncoded: true)
            path = url.path(percentEncoded: false)
            pathComponents = url.pathComponents
            self.authCallback = authCallback
        }
    }

    /// A file URL's file, as the app found it (Rust `File`).
    nonisolated struct File: Encodable, Sendable {
        var path: String, folder: String, ext: String
        var isDirectory: Bool, isExecutable: Bool, isImage: Bool
    }

    nonisolated struct RouteRequest: Encodable, Sendable {
        var link: Link, file: File?, linkScheme: String?, mode: String
    }

    /// Where the link goes (Rust `Route`); the URL itself comes from the request.
    nonisolated struct RouteReply: Decodable, Sendable {
        var kind: String
        var cwd: String?
        var command: String?
        var target: SSHLinkTarget.Wire?

        func route(_ url: URL) -> ExternalOpenRoute {
            switch kind {
            case "browserTab": .browserTab(url)
            case "browserFile": .browserTab(URL(fileURLWithPath: url.path))
            case "terminal": .terminal(cwd: cwd, command: command)
            case "ssh": target.map { .ssh(SSHLinkTarget(user: $0.user, host: $0.host, port: $0.port)) } ?? .unsupported
            case "attachImage": .attachImages([URL(fileURLWithPath: url.path)], from: nil)
            case "file": .file(URL(fileURLWithPath: url.path))
            case "deepLink": .deepLink(url)
            case "shareLink": .shareLink(url)
            default: .unsupported
            }
        }
    }

    nonisolated struct SignInCallback: Encodable, Sendable {
        nonisolated struct Reply: Decodable, Sendable { var callback: Bool }
        var host: String?, path: String
    }
}

extension SSHLinkTarget {
    /// The target as Rust reads it (`SshTarget`).
    nonisolated struct Wire: Codable, Sendable {
        var user: String?, host: String, port: Int?

        init(_ target: SSHLinkTarget) {
            user = target.user
            host = target.host
            port = target.port
        }
    }

    /// Its confirmation text, trust key and command (Rust `SshStrings`).
    nonisolated struct Strings: Decodable, Sendable {
        var display: String, trustKey: String, command: String
    }
}
