public import CmuxNextCompat
public import Foundation

/// Where libghostty and the shells find Ghostty's resources (themes, shell integration):
/// ``prepareProcessEnvironment(resources:environmentGuard:)`` points libghostty at one of these.
extension GhosttyRuntime {
    /// This app's bundled Ghostty resources, `<Resources>/ghostty`, from the
    /// bundle's paths alone (no disk call): the build phase
    /// (scripts/cmux-next/bundle-ghostty-resources.sh) puts the themes and the
    /// shell integration there. Nil outside an app bundle (tests, a bare binary).
    public nonisolated static func bundledResourcesDirectory(bundleURL: URL = Bundle.main.bundleURL,
                                                             resourceURL: URL? = Bundle.main.resourceURL) -> String? {
        guard bundleURL.pathExtension == "app", let resourceURL else { return nil }
        return resourceURL.appendingPathComponent("ghostty").path
    }

    /// The Ghostty resources directory (themes, shell integration; terminfo
    /// is its sibling): this app's bundled copy, then an inherited
    /// `GHOSTTY_RESOURCES_DIR`, then Ghostty.app. Nil when none has themes.
    /// Each candidate is a disk check; the launch makes them on a lane
    /// (`GhosttyLaunchProbe`).
    public nonisolated static func resourcesDirectory(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) }
    ) -> String? {
        let bundled = bundle.resourceURL?.appendingPathComponent("ghostty")
        let inherited = environment["GHOSTTY_RESOURCES_DIR"]
        let ghosttyApp = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let candidates = [bundled?.path, inherited, ghosttyApp].compactMap { $0 }
        return candidates.first { fileExists(($0 as NSString).appendingPathComponent("themes")) }
    }
}
