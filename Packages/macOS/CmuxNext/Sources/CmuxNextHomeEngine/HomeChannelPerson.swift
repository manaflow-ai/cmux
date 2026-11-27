/// A person New Channel invites (plans/cmux-next/chief-channels-DESIGN.md): an email address, which
/// gets an invite (`invite.create`), or an account the user already reaches, which is added at once
/// (`participants.add`).
public nonisolated enum HomeChannelPerson: Hashable, Sendable {
    /// An email address; the owner sends the invite.
    case email(String)
    /// A Worker account id (`user_…`): a teammate or a connection.
    case account(String)

    /// How the person is named in a result line: the address or the account id.
    public var label: String {
        switch self {
        case .email(let address): address
        case .account(let id): id
        }
    }
}
