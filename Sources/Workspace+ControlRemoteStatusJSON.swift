import CmuxControlSocket
import Foundation

extension Workspace {
    /// The workspace's `remoteStatusPayload()` bridged to the control-plane
    /// ``JSONValue`` wire type, falling back to an empty object when the
    /// Foundation payload is not encodable.
    ///
    /// Every `workspace.remote.*` control witness (disconnect / reconnect /
    /// foreground-auth-ready / status / pty-attach-end / terminal-session-end /
    /// configure) and the workspace summary built the identical
    /// `JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:])`
    /// expression inline; this computed property is the single source of truth
    /// for that bridge, byte-identical to the former inline form.
    var controlRemoteStatusJSON: JSONValue {
        JSONValue(foundationObject: remoteStatusPayload()) ?? .object([:])
    }
}
