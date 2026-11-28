public import Foundation

/// Where the CEF runtime lives inside an app bundle (or a directory named by
/// `CMUX_NEXT_CEF_RUNTIME`, for demos that are not bundled apps).
///
/// `scripts/cmux-next/embed-cef.sh` produces this layout in
/// `<App>.app/Contents/Frameworks`:
///
///     Chromium Embedded Framework.framework/
///     libcmux_cef_shim.dylib
///     <App> Helper.app, <App> Helper (GPU).app, (Renderer), (Plugin), (Alerts)
public nonisolated struct CEFRuntimeLayout: Hashable, Sendable {
    public static let frameworkName = "Chromium Embedded Framework.framework"
    public static let shimName = "libcmux_cef_shim.dylib"

    public var frameworksDirectory: URL
    /// The `.app` CEF treats as the main bundle.
    public var mainBundle: URL
    /// The base helper app (`<App> Helper.app`).
    public var helperApp: URL

    public var frameworkDirectory: URL { frameworksDirectory.appending(path: Self.frameworkName) }
    public var frameworkBinary: URL { frameworkDirectory.appending(path: "Chromium Embedded Framework") }
    public var shim: URL { frameworksDirectory.appending(path: Self.shimName) }
    public var helperExecutable: URL {
        helperApp.appending(path: "Contents/MacOS").appending(path: helperApp.deletingPathExtension().lastPathComponent)
    }

    public init(frameworksDirectory: URL, mainBundle: URL, helperApp: URL) {
        self.frameworksDirectory = frameworksDirectory
        self.mainBundle = mainBundle
        self.helperApp = helperApp
    }

    /// Picks the base helper among the entries of a Frameworks directory:
    /// the one named exactly `<Name> Helper.app` (not a `(Kind)` variant).
    public static func baseHelperName(in entries: [String]) -> String? {
        entries
            .filter { $0.hasSuffix(" Helper.app") }
            .sorted()
            .first
    }

    /// Resolves the layout for `bundle`, or nil when CEF was not embedded
    /// (the build skipped CEF or the artifact was unavailable).
    public static func locate(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> CEFRuntimeLayout? {
        let frameworks: URL
        if let override = environment["CMUX_NEXT_CEF_RUNTIME"], !override.isEmpty {
            frameworks = URL(filePath: override, directoryHint: .isDirectory)
        } else if let url = bundle.privateFrameworksURL {
            frameworks = url
        } else {
            return nil
        }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: frameworks.path),
              entries.contains(frameworkName), entries.contains(shimName),
              let helper = baseHelperName(in: entries) else {
            return nil
        }
        // For an override directory, the main bundle is the app that holds it.
        let main = frameworks.deletingLastPathComponent().deletingLastPathComponent()
        return CEFRuntimeLayout(
            frameworksDirectory: frameworks,
            mainBundle: main.pathExtension == "app" ? main : bundle.bundleURL,
            helperApp: frameworks.appending(path: helper)
        )
    }
}
