/// How Chief's own turns handle permission asks: the values of `chief.permissionMode`
/// (schemas/settings/source/chief-permission.json), which the Chief host reads at each turn start.
public enum ChiefPermissionMode: String, CaseIterable, Hashable, Sendable {
    /// Bypass (the default): Chief runs each command without asking.
    case bypass = "bypassPermissions"
    /// Auto: a safety check approves or refuses each command.
    case auto
    /// Manual: Chief stops at each change that would need approval.
    case manual = "default"

    /// The mode with no `chief.permissionMode` in the settings.
    public static let `default` = ChiefPermissionMode.bypass
}
