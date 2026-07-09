/// How a `cmux.json` workspace command treats an already-open workspace that
/// matches its target: open a `new` one, `recreate` (close + reopen), `ignore`
/// (focus the existing one), or `confirm` (prompt the user).
public enum CmuxRestartBehavior: String, Codable, Sendable {
    case new
    case recreate
    case ignore
    case confirm
}
