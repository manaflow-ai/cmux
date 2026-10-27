#if canImport(AppKit)
import CmuxNextCompat
public import Foundation

extension ImportEnvironment {
    /// ``live(environment:allowsFixtures:locateApp:)`` with apps found through Launch Services' checked seam
    /// (`WorkspaceQuerying.application(withBundleIdentifier:)`): detection runs off the main thread. The seam is
    /// AppKit's, so this overload is Apple-only; the Linux tier passes its own lookup.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowsFixtures: Bool = fixturesAllowed
    ) -> ImportEnvironment {
        live(environment: environment, allowsFixtures: allowsFixtures,
             locateApp: { SystemWorkspaceQuerying().application(withBundleIdentifier: $0) })
    }
}
#endif
