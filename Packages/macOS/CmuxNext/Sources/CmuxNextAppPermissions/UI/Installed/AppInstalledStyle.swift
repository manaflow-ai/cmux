public import Observation

/// The Installed Apps prototypes (DEV/NIGHTLY switch, Debug Settings key
/// `apps.installed.style`). Cards are the default (Lawrence's pick for the
/// store layouts).
public nonisolated enum AppInstalledStyle: String, Sendable, Hashable, CaseIterable, Codable {
    case cards
    case rows

    public static let settingKey = "apps.installed.style"
    public static let defaultStyle = AppInstalledStyle.cards
}

/// Where the Installed Apps list reads its style. The App conforms its
/// Debug Settings store; `AppInstalledStyleSetting` is the standalone one.
@MainActor
public protocol AppInstalledStyleSource: AnyObject, Observable {
    var installedStyle: AppInstalledStyle { get }
}

/// A standalone observable Installed Apps style setting.
@MainActor
@Observable
public final class AppInstalledStyleSetting: AppInstalledStyleSource {
    public var installedStyle: AppInstalledStyle

    public init(_ style: AppInstalledStyle = .defaultStyle) { installedStyle = style }

    public func set(rawValue: String) { installedStyle = AppInstalledStyle(rawValue: rawValue) ?? .defaultStyle }
}
