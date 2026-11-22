public import Observation

/// The permissions presentation prototypes (DEV/NIGHTLY switch,
/// Debug Settings key `apps.permissions.style`). Lawrence picks one.
public nonisolated enum AppPermissionsStyle: String, Sendable, Hashable, CaseIterable, Codable {
    /// Scopes grouped by axis (cmux, Network, Files, Commands, ...) with
    /// risk tones; a profile picker on top.
    case grouped
    /// One flat list sorted by risk, with a "Run sandboxed" master switch.
    case flat
    /// A compact capability matrix: one row per scope, one column per
    /// approval mode.
    case matrix

    /// The Debug Settings key the App binds.
    public static let settingKey = "apps.permissions.style"
    public static let defaultStyle = AppPermissionsStyle.grouped
}

/// Where the surfaces read the style. The App conforms its Debug Settings
/// store (an `@Observable` value), so a change re-renders live.
@MainActor
public protocol AppPermissionsStyleSource: AnyObject, Observable {
    var permissionsStyle: AppPermissionsStyle { get }
}

/// A standalone observable setting (demos, tests, and the App until it
/// binds Debug Settings).
@MainActor
@Observable
public final class AppPermissionsStyleSetting: AppPermissionsStyleSource {
    public var permissionsStyle: AppPermissionsStyle

    public init(_ style: AppPermissionsStyle = .defaultStyle) {
        permissionsStyle = style
    }

    /// Parses the Debug Settings value; unknown values fall back to the default.
    public func set(rawValue: String) {
        permissionsStyle = AppPermissionsStyle(rawValue: rawValue) ?? .defaultStyle
    }
}
