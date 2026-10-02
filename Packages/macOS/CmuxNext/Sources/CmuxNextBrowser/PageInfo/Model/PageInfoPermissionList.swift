import Foundation

/// Which permission rows Page Info lists, in Chromium's order
/// (`PageInfo::ShouldShowPermission`): a permission shows when the user
/// changed it from the default, when the page requested or is using it
/// during this page load, or when it changed since the page loaded (so a
/// row set back to the default does not vanish under the pointer).
public nonisolated enum PageInfoPermissionList {
    /// - Parameters:
    ///   - decisions: stored decisions for the origin.
    ///   - live: the engine's own current values where it keeps them
    ///     (Chromium asks the page's `navigator.permissions`); used for
    ///     kinds without a stored decision.
    public static func rows(
        supported: Set<SitePermissionKind>,
        decisions: [SitePermissionKind: SitePermissionSetting],
        live: [SitePermissionKind: SitePermissionSetting] = [:],
        requested: Set<SitePermissionKind> = [],
        inUse: Set<SitePermissionKind> = [],
        changedSinceLoad: Set<SitePermissionKind> = []
    ) -> [SitePermissionState] {
        SitePermissionKind.allCases.compactMap { kind in
            guard supported.contains(kind) else { return nil }
            let stored = decisions[kind]
            let observed = stored == nil ? live[kind] : nil
            let setting = stored ?? observed ?? kind.defaultSetting
            let isDefault = setting == kind.defaultSetting
            let show = !isDefault || requested.contains(kind) || inUse.contains(kind) || changedSinceLoad.contains(kind)
            guard show else { return nil }
            return SitePermissionState(kind: kind, setting: setting, isDefault: isDefault, isInUse: inUse.contains(kind))
        }
    }

    /// "Reset permission(s)" shows when a listed row is not the default.
    public static func resettableCount(_ rows: [SitePermissionState]) -> Int {
        rows.filter { !$0.isDefault }.count
    }
}
