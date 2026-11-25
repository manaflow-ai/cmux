import Foundation

// `cloud-host-replica-v1` (plans/cmux-next/object-sync/DESIGN.md phase 3,
// cmux-tui/spec/commands.md): the daemon publishes a narrow copy of this
// Mac's workspace list to the Cloud service with the app's install token.
// The verified app connection only.
//
// The request structs are generated at build time from cmux-tui/spec/sdk-schema.json
// (scripts/cmux-next/gen-conversation-wire.py, ConversationWireTypesPlugin).

extension CloudHostReplicaSetRequest: CustomStringConvertible {
    /// Never prints the token.
    public var description: String { "cloud-host-replica-set(\(apiBaseURL), expires_at: \(expiresAt))" }
}
