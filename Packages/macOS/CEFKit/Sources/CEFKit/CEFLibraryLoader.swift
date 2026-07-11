import CCEF
import Foundation

/// Loads the Chromium Embedded Framework binary with dlopen before any
/// libcef symbol is called. All libcef entry points are then resolved with
/// dlsym (CEFRuntime), so host apps need no CEF-related linker flags.
/// Internal seam: host apps load through CEFApp (initialize / helperMain).
enum CEFLibraryLoader {
    private static let frameworkBinaryPath = "Chromium Embedded Framework.framework/Chromium Embedded Framework"
    private static var loaded = false

    static var isLoaded: Bool { loaded }

    /// Loads the framework from the main app bundle's Frameworks directory
    /// and pins the CEF API version. Call first in the browser process.
    @discardableResult
    static func loadInMainProcess() -> Bool {
        guard let frameworksURL = Bundle.main.privateFrameworksURL else { return false }
        return load(from: frameworksURL.appendingPathComponent(frameworkBinaryPath))
    }

    /// Loads the framework from a helper app's position inside the main
    /// bundle (Contents/Frameworks/<X> Helper.app/Contents/MacOS/<X> Helper).
    @discardableResult
    static func loadInHelperProcess() -> Bool {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let frameworksDir = executable
            .deletingLastPathComponent()  // <X> Helper (binary)
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // <X> Helper.app
        return load(from: frameworksDir.appendingPathComponent(frameworkBinaryPath))
    }

    @discardableResult
    static func load(from binaryURL: URL) -> Bool {
        if loaded { return true }
        guard dlopen(binaryURL.path, RTLD_LAZY | RTLD_GLOBAL) != nil else {
            FileHandle.standardError.write(Data("CEFKit: failed to dlopen \(binaryURL.path): \(String(cString: dlerror()))\n".utf8))
            return false
        }
        loaded = true
        // CEF >= 126 requires selecting the API version before any other call;
        // the capi structs in this distribution are versioned.
        _ = CEFRuntime.apiHash(cefkit_api_version_last, 0)
        return true
    }
}
