import Foundation

/// Strings of Mac Screen tabs (Resources/Localizable.xcstrings).
nonisolated enum L {
    static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}

/// Permission copy that names the app whose switch the person turns on in System Settings: the
/// helper holding the grants (``MacScreenShareHost/grantHolderName``, "cmux Computer Use" in a
/// release, NIGHTLY or RC build), or this app in a build without the helper.
nonisolated enum MacScreenGrantCopy {
    /// The name System Settings lists the grants under: `helper`, else this app's own name.
    static func holder(_ helper: String?, app bundle: Bundle = .main) -> String {
        if let helper, !helper.isEmpty { return helper }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle.object(forInfoDictionaryKey: key) as? String, !name.isEmpty { return name }
        }
        return "cmux"
    }

    /// The guide's Screen Recording step: who needs the grant.
    static func setupScreenBody(_ helper: String?, app bundle: Bundle = .main) -> String {
        String(format: L.t("macScreen.setup.screen.body.holder", "macOS needs Screen Recording permission for “%@” to share your display."),
               holder(helper, app: bundle))
    }

    /// The guide's permission steps: which switch to turn on.
    static func setupAllow(_ helper: String?, app bundle: Bundle = .main) -> String {
        String(format: L.t("macScreen.setup.allow.holder", "Allow “%@” in the macOS permission prompt or System Settings, then return here and check again."),
               holder(helper, app: bundle))
    }

    /// The Screen Recording row's detail. Without the helper the grant is this app's, and macOS
    /// may ask to reopen it; the helper's grant never restarts this app.
    static func screenRecordingDetail(_ helper: String?) -> String {
        guard let helper, !helper.isEmpty else {
            return L.t("macScreen.home.screenRecordingDetail", "Lets cmux send this screen. macOS may ask you to quit and reopen cmux.")
        }
        return String(format: L.t("macScreen.home.screenRecordingDetail.holder", "Lets “%@” send this screen."), helper)
    }

    /// The Screen Recording row's detail while the grant is missing.
    static func screenRecordingNeeded(_ helper: String?) -> String {
        guard let helper, !helper.isEmpty else {
            return L.t("macScreen.home.screenRecordingNeeded", "Needed to send this screen. macOS may ask you to reopen cmux.")
        }
        return String(format: L.t("macScreen.home.screenRecordingNeeded.holder", "Needed to send this screen. Turn on “%@” in System Settings."), helper)
    }
}
