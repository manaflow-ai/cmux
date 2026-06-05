import Foundation

/// Settings under the dotted-id prefix `window.*`.
///
/// Controls how new main windows are sized on open. By default cmux restores
/// the last-used window geometry; enabling ``openAtFixedSize`` makes every
/// freshly created window open at ``width`` × ``height`` points instead. The
/// runtime policy and precedence rules live in ``WindowOpenSizeSettings``; these
/// keys are the UI/storage handles bound by the Settings UI and `cmux.json`.
public struct WindowCatalogSection: SettingCatalogSection {
    /// Open new main windows at a fixed ``width`` × ``height`` instead of
    /// restoring the last-used window size. Defaults to off, so existing
    /// restore-last-size behavior is unchanged until opted in.
    public let openAtFixedSize = DefaultsKey<Bool>(
        id: "window.openAtFixedSize",
        defaultValue: WindowOpenSizeSettings.defaultOpenAtFixedSize,
        userDefaultsKey: WindowOpenSizeSettings.openAtFixedSizeStorageKey
    )

    /// Fixed window width, in points, applied when ``openAtFixedSize`` is on.
    public let width = DefaultsKey<Int>(
        id: "window.width",
        defaultValue: Int(WindowOpenSizeSettings.defaultWidth),
        userDefaultsKey: WindowOpenSizeSettings.widthStorageKey
    )

    /// Fixed window height, in points, applied when ``openAtFixedSize`` is on.
    public let height = DefaultsKey<Int>(
        id: "window.height",
        defaultValue: Int(WindowOpenSizeSettings.defaultHeight),
        userDefaultsKey: WindowOpenSizeSettings.heightStorageKey
    )

    /// Creates the window settings section with its default keys.
    public init() {}
}
