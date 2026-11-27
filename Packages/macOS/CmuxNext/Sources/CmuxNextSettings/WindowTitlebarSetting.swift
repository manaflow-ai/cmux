public import CmuxNextDesign

/// `window.titlebar` in cmux.json: "minimal" (default: no titlebar strip,
/// the top row's empty space moves the window) or "standard" (a titlebar
/// strip with the workspace name).
public nonisolated struct WindowTitlebarSetting {
    public nonisolated init() {}
}

/// `window.titlebarButtons` in cmux-next.json (R83): "hover" (default) or
/// "always".
public nonisolated struct TitlebarButtonsSetting {
    public nonisolated init() {}
}

/// `tabs.plusButton` in cmux-next.json (R120): "hover" (default) or "always".
public nonisolated struct PlusButtonSetting {
    public nonisolated init() {}
}
