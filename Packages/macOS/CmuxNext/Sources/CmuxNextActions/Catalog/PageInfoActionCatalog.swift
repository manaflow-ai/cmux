// Page Info (the omnibar's "View site information" bubble). Titles live in
// PageInfoActions.xcstrings. Ids match the PageInfo action constants in
// CmuxNextBrowser; every bubble control runs one of these.

nonisolated enum PageInfoActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            page("browser.pageInfo", title: t("action.pageInfo", "View Site Information"), symbol: "slider.horizontal.3",
                 keywords: ["site", "information", "security", "certificate", "permissions", "cookies", "lock"],
                 cli: "browser page-info", shortcut: Shortcut("i", modifiers: [.control, .command])),
            page("browser.pageInfo.connection", title: t("action.pageInfo.connection", "Show Connection Details"), symbol: "lock",
                 keywords: ["site", "security", "https", "connection", "secure"], cli: "browser page-info-connection"),
            page("browser.pageInfo.certificate", title: t("action.pageInfo.certificate", "Show Certificate"), symbol: "checkmark.seal",
                 keywords: ["site", "certificate", "tls", "ssl", "fingerprint"], cli: "browser page-info-certificate"),
            page("browser.pageInfo.reenableCertificateWarnings",
                 title: t("action.pageInfo.reenableCertificateWarnings", "Turn On Certificate Warnings Again"),
                 symbol: "exclamationmark.shield",
                 keywords: ["site", "certificate", "security", "warning", "interstitial", "tls", "ssl", "re-enable", "revoke"],
                 cli: "browser reenable-certificate-warnings"),
            page("browser.pageInfo.cookies", title: t("action.pageInfo.cookies", "Show Cookies and Site Data"), symbol: "cylinder.split.1x2",
                 keywords: ["site", "cookies", "storage", "data"], cli: "browser page-info-cookies"),
            page("browser.pageInfo.manageSiteData", title: t("action.pageInfo.manageSiteData", "Manage On-Device Site Data"),
                 symbol: "tray.full", keywords: ["site", "cookies", "storage", "data", "delete"], cli: "browser manage-site-data"),
            ActionDescriptor(
                id: "browser.pageInfo.deleteSiteData",
                title: t("action.pageInfo.deleteSiteData", "Delete Site Data"),
                keywords: ["site", "cookies", "storage", "clear", "delete"], category: .browser, symbol: "trash",
                surfaces: allSurfaces, requires: [.browserFocused], arguments: [domainArgument.optional], targets: [.pane],
                cliName: "browser delete-site-data", destructive: true
            ),
            ActionDescriptor(
                id: "browser.pageInfo.setPermission",
                title: t("action.pageInfo.setPermission", "Set Site Permission…"),
                keywords: ["site", "permission", "camera", "microphone", "location", "notifications", "javascript", "allow", "block"],
                category: .browser, symbol: "hand.raised", surfaces: allSurfaces, requires: [.browserFocused],
                arguments: [permissionArgument, settingArgument], targets: [.pane], cliName: "browser set-site-permission"
            ),
            page("browser.pageInfo.resetPermissions", title: t("action.pageInfo.resetPermissions", "Reset Site Permissions"),
                 symbol: "arrow.counterclockwise", keywords: ["site", "permission", "reset"], cli: "browser reset-site-permissions"),
            page("browser.pageInfo.siteSettings", title: t("action.pageInfo.siteSettings", "Site Settings"), symbol: "gearshape",
                 keywords: ["site", "settings", "permissions"], cli: "browser site-settings"),
            page("browser.pageInfo.aboutThisPage", title: t("action.pageInfo.aboutThisPage", "About This Page"),
                 symbol: "doc.text.magnifyingglass", keywords: ["site", "about", "source"], cli: "browser about-this-page"),
        ]
    }

    /// Every Page Info control is in the palette, the browser page context
    /// menu's Site Information submenu, the CLI, and takes a user shortcut.
    private static let allSurfaces: ActionSurfaces = [.palette, .keyboard, .contextMenu]

    private static func page(_ id: ActionID, title: String, symbol: String, keywords: [String], cli: String,
                             shortcut: Shortcut? = nil) -> ActionDescriptor {
        ActionDescriptor(id: id, title: title, keywords: keywords, defaultShortcut: shortcut, category: .browser, symbol: symbol,
                         surfaces: allSurfaces, requires: [.browserFocused], targets: [.pane], cliName: cli)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "PageInfoActions", bundle: .module)
    }

    /// Permission ids (`SitePermissionKind.rawValue` in CmuxNextBrowser).
    static let permissionIDs = ["location", "camera", "microphone", "notifications", "javascript", "images", "popups",
                                "sound", "automaticDownloads", "midi", "usb", "serial", "hid", "clipboard", "sensors",
                                "bluetooth", "fileEditing", "windowManagement", "localFonts", "backgroundSync",
                                "autoPictureInPicture", "thirdPartySignIn", "insecureContent"]

    private static var permissionArgument: ActionArgument {
        let titles: [String: String] = [
            "location": t("argument.permission.location", "Location"),
            "camera": t("argument.permission.camera", "Camera"),
            "microphone": t("argument.permission.microphone", "Microphone"),
            "notifications": t("argument.permission.notifications", "Notifications"),
            "javascript": t("argument.permission.javascript", "JavaScript"),
            "images": t("argument.permission.images", "Images"),
            "popups": t("argument.permission.popups", "Pop-ups and redirects"),
            "sound": t("argument.permission.sound", "Sound"),
            "automaticDownloads": t("argument.permission.automaticDownloads", "Automatic downloads"),
            "midi": t("argument.permission.midi", "MIDI device control & reprogram"),
            "usb": t("argument.permission.usb", "USB devices"),
            "serial": t("argument.permission.serial", "Serial ports"),
            "hid": t("argument.permission.hid", "HID devices"),
            "clipboard": t("argument.permission.clipboard", "Clipboard"),
            "sensors": t("argument.permission.sensors", "Motion sensors"),
            "bluetooth": t("argument.permission.bluetooth", "Bluetooth devices"),
            "fileEditing": t("argument.permission.fileEditing", "File editing"),
            "windowManagement": t("argument.permission.windowManagement", "Window management"),
            "localFonts": t("argument.permission.localFonts", "Fonts"),
            "backgroundSync": t("argument.permission.backgroundSync", "Background sync"),
            "autoPictureInPicture": t("argument.permission.autoPictureInPicture", "Auto picture-in-picture"),
            "thirdPartySignIn": t("argument.permission.thirdPartySignIn", "Third-party sign-in"),
            "insecureContent": t("argument.permission.insecureContent", "Insecure content"),
        ]
        return ActionArgument(name: "permission", title: t("argument.permission", "Permission"),
                              kind: .enumeration(permissionIDs.map { ActionEnumCase(value: $0, title: titles[$0] ?? $0) }))
    }

    private static var settingArgument: ActionArgument {
        ActionArgument(name: "setting", title: t("argument.setting", "Setting"), kind: .enumeration([
            ActionEnumCase(value: "ask", title: t("argument.setting.ask", "Ask")),
            ActionEnumCase(value: "allow", title: t("argument.setting.allow", "Allow")),
            ActionEnumCase(value: "block", title: t("argument.setting.block", "Block")),
        ]))
    }

    private static var domainArgument: ActionArgument {
        ActionArgument(name: "domain", title: t("argument.domain", "Site"), kind: .string)
    }
}
