public import Foundation

/// The control plane's answer to `POST /api/vm/<id>/attach-endpoint` for the
/// `cmux-remote` transport.
public struct CloudAttachEndpoint: Sendable, Equatable {
    /// A first-contact invitation the daemon accepts from an unenrolled device.
    public struct Invitation: Sendable, Equatable {
        /// The invitation URI handed to the client.
        public var uri: String
        /// The id the control plane approves through `/cmux-remote/approve`.
        public var invitationId: String

        /// Creates an invitation.
        public init(uri: String, invitationId: String) {
            self.uri = uri
            self.invitationId = invitationId
        }
    }

    /// The daemon route (`ws://[vpc ipv6]:1337/v1/link` for private machines).
    public var route: String
    /// The control plane's session id for this attach.
    public var session: String
    /// Present on a device's first contact with this machine.
    public var invitation: Invitation?

    /// Creates an attach endpoint.
    public init(route: String, session: String, invitation: Invitation? = nil) {
        self.route = route
        self.session = session
        self.invitation = invitation
    }
}
