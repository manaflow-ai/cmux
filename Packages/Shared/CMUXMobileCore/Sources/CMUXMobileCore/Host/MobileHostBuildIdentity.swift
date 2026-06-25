import Foundation

/// The Mac app's user-facing version and build numbers, read from the running
/// bundle's `Info.plist`.
///
/// `mobile.host.status` and the identity reply hand these two `String?` values to
/// `MobileHostStatusPayloadProjector` so iOS can show the paired Mac's app
/// version and build. The values originate app-side (`Bundle.main`), so the app
/// resolves them with `current()` and passes the result into the projector rather
/// than the projector reaching for `Bundle`.
///
/// Not `Sendable`: the factory reads `Bundle`, but the resolved value is a pair of
/// `String?` produced once at the app call site and never crosses an isolation
/// boundary as a `MobileHostBuildIdentity`.
public struct MobileHostBuildIdentity {
    /// `CFBundleShortVersionString` (the marketing version, e.g. `0.64.15`),
    /// trimmed and `nil` when absent or empty.
    public let appVersion: String?

    /// `CFBundleVersion` (the build number), trimmed and `nil` when absent or
    /// empty.
    public let appBuild: String?

    /// Reads the version and build strings from `bundle`'s `Info.plist`.
    ///
    /// - Parameter bundle: the bundle to read; defaults to `.main`, the running
    ///   app bundle whose `Info.plist` carries the real version and build.
    public static func current(bundle: Bundle = .main) -> MobileHostBuildIdentity {
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
