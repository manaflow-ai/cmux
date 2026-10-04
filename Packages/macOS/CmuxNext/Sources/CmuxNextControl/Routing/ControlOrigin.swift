public import CmuxNextSettings

/// Who a control request says it acts for (`origin`), and who may say so
/// (identity.md section 3, OWNERSHIP-PRINCIPLES). A caller on the control
/// socket is never the in-app user: only in-process callers (cmux apps,
/// whose engine sets `user` only after a gesture) may name `user`. `action.run` and `palette.run` share
/// this one rule.
public enum ControlOrigin {
    /// The origins any caller may name.
    public static let headless: Set<String> = ["cli", "mcp", "script", "remote"]

    /// The checked `origin` of a request on `connection`, or nil when the
    /// request names none (a CLI run).
    public static func validated(_ value: JSONValue?, connection: ControlConnectionID) throws -> String? {
        try validated(value, allowsUser: connection == .inProcess)
    }

    /// The checked `origin`; `user` only when `allowsUser`.
    public static func validated(_ value: JSONValue?, allowsUser: Bool) throws -> String? {
        guard let value, !value.isNull else { return nil }
        if let name = value.stringValue, headless.contains(name) || (allowsUser && name == "user") {
            return name
        }
        throw allowsUser
            ? ControlError.invalidParams(ControlStrings.text("control.error.origin", "origin must be user, cli, mcp, script or remote"))
            : ControlError.invalidParams(ControlStrings.text("control.error.originHeadless", "origin must be cli, mcp, script or remote"))
    }
}
