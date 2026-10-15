import Foundation

/// A name and value on their way into the vault.
///
/// Every textual rendering redacts the value: `print`, string interpolation, `dump`,
/// debugger summaries and `Mirror` all show `<redacted>`, so a stray log line or test
/// failure message cannot leak it.
public struct CloudSecretInput: Hashable, Sendable {
    /// Longest accepted value, in UTF-8 bytes.
    public static let maxValueBytes = 32 * 1_024

    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    /// Checks the name rules (see ``validateName(_:)``) and the value rules: non-empty,
    /// a single line (``CloudEnvDelivery`` refuses newlines), at most ``maxValueBytes``.
    public func validate() throws {
        try Self.validateName(name)
        if value.isEmpty { throw CloudSecretValidationError.emptyValue(name) }
        if value.contains("\n") || value.contains("\r") { throw CloudSecretValidationError.multilineValue(name) }
        if value.utf8.count > Self.maxValueBytes { throw CloudSecretValidationError.valueTooLarge(name) }
    }

    /// Names match `^[A-Za-z_][A-Za-z0-9_]{0,127}$` and are not reserved (see ``isReservedName(_:)``).
    public static func validateName(_ name: String) throws {
        try validateNameSyntax(name)
        if isReservedName(name) { throw CloudSecretValidationError.reservedName(name) }
    }

    /// The name's shape only, reserved or not. Removal uses it, so a name stored
    /// before it became reserved can still be removed.
    public static func validateNameSyntax(_ name: String) throws {
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}\\z", options: .regularExpression) != nil else {
            throw CloudSecretValidationError.invalidName(name)
        }
    }

    /// Names the machine's own shell or cmux owns: every login shell and every cmux exec
    /// on the machine sources the machine env, so overriding them would break program
    /// lookup, the work user's home, word splitting or shell startup (`IFS`, `ENV`,
    /// `BASH_ENV`, `PS4`, `PROMPT_COMMAND`), inject code (`LD_*`, `DYLD_*`), or confuse
    /// the cmux shim (`CMUX_*`). Compared case-insensitively. The machine's
    /// `cmux env set` refuses the same list (`env_key_reserved` in the guest shim,
    /// web/services/vms/guestCli.ts).
    public static func isReservedName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return reservedNames.contains(upper) || reservedPrefixes.contains { upper.hasPrefix($0) }
    }

    static let reservedNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "IFS", "ENV", "BASH_ENV", "PS4", "PROMPT_COMMAND",
        "PWD", "OLDPWD", "TERM",
    ]

    static let reservedPrefixes: [String] = ["LD_", "DYLD_", "CMUX_"]
}

extension CloudSecretInput: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "CloudSecretInput(name: \(name), value: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["name": name, "value": "<redacted>"], displayStyle: .struct)
    }
}
