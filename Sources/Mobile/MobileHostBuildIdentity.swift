import Foundation

struct MobileHostBuildIdentity {
    let appVersion: String?
    let appBuild: String?

    static func current(bundle: Bundle = .main) -> MobileHostBuildIdentity {
        let bundleAppVersion = normalized(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
#if DEBUG
        let appVersion = normalized(ProcessInfo.processInfo.environment["CMUX_DEBUG_MOBILE_APP_VERSION"])
            ?? bundleAppVersion
#else
        let appVersion = bundleAppVersion
#endif

        return MobileHostBuildIdentity(
            appVersion: appVersion,
            appBuild: normalized(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
