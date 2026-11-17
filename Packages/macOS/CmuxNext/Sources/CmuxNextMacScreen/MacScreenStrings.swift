import Foundation

/// Strings of Mac Screen tabs (Resources/Localizable.xcstrings).
nonisolated enum L {
    static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}

/// Permission copy that names the app whose switch the person turns on in System Settings: the
/// helper holding the grants (``MacScreenShareHost/grantHolderName``, as its host names itself),
/// and "cmux Computer Use" until the host has answered. Never this app: it holds no Mac Screen
/// grant, and a grant never relaunches it.
nonisolated enum MacScreenGrantCopy {
    /// The helper's name in System Settings in a release, NIGHTLY or RC build.
    static let helperName = "cmux Computer Use"

    /// The name System Settings lists the grants under: `helper`, else ``helperName``.
    static func holder(_ helper: String?) -> String {
        if let helper, !helper.isEmpty { return helper }
        return helperName
    }

    /// The guide's Screen Recording step: who needs the grant.
    static func setupScreenBody(_ helper: String?) -> String {
        String(format: L.t("macScreen.setup.screen.body.holder", "macOS needs Screen Recording permission for “%@” to share your display."),
               holder(helper))
    }

    /// The guide's permission steps: which switch to turn on.
    static func setupAllow(_ helper: String?) -> String {
        String(format: L.t("macScreen.setup.allow.holder", "Allow “%@” in the macOS permission prompt or System Settings, then return here and check again."),
               holder(helper))
    }

    /// The Screen Recording row's detail (the helper's grant never restarts this app).
    static func screenRecordingDetail(_ helper: String?) -> String {
        String(format: L.t("macScreen.home.screenRecordingDetail.holder", "Lets “%@” send this screen."), holder(helper))
    }

    /// The Screen Recording row's detail while the grant is missing.
    static func screenRecordingNeeded(_ helper: String?) -> String {
        String(format: L.t("macScreen.home.screenRecordingNeeded.holder", "Needed to send this screen. Turn on “%@” in System Settings."), holder(helper))
    }
}
