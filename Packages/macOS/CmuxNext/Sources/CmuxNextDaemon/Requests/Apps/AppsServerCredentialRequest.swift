import Foundation

/// `apps-server-credential`: the person approves a credential for an installed app's external
/// server (`server.kind: external`, any language). The daemon answers `{app, credential}` once
/// and keeps only its SHA-256 digest; the server presents it on `apps-server-attach`
/// (`CMUX_APP_CREDENTIAL`). Origin `user` only, on the verified cmux app connection: anything
/// else answers `apps.gesture_required` (cmux-tui-core apps/server_external.rs).
public struct AppsServerCredentialRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-server-credential"

    public var app: String
    public var origin: AppsRunRequest.Origin

    public init(app: String) {
        self.app = app
        self.origin = .user
    }
}
