import Foundation

struct MobileHostBuildIdentity {
    let appVersion: String?
    let appBuild: String?

    static func current(bundle: Bundle = .main) -> MobileHostBuildIdentity {
        MobileHostBuildIdentity(
            appVersion: normalized(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            appBuild: normalized(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
