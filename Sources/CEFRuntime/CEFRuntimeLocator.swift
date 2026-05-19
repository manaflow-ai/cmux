import Foundation

struct CEFRuntimeLocation: Equatable, Sendable {
    let versionRoot: URL
    let frameworksDirectory: URL

    var frameworkBinaryURL: URL {
        frameworksDirectory
            .appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
            .appendingPathComponent("Versions/A/Chromium Embedded Framework")
    }

    var helperExecutableURL: URL {
        frameworksDirectory
            .appendingPathComponent("cmux Helper.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/cmux Helper")
    }

    var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: frameworkBinaryURL.path)
    }
}

enum CEFRuntimeLocator {
    static func applicationSupportRoot(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent(bundleIdentifier ?? "com.cmuxterm.app", isDirectory: true)
            .appendingPathComponent("CEFRuntime", isDirectory: true)
    }

    static func installedLocation(
        descriptor: CEFRuntimeDescriptor = .current,
        root: URL? = nil,
        fileManager: FileManager = .default
    ) -> CEFRuntimeLocation? {
        let runtimeRoot: URL
        if let root {
            runtimeRoot = root
        } else {
            guard let resolved = try? applicationSupportRoot(fileManager: fileManager) else {
                return nil
            }
            runtimeRoot = resolved
        }
        let versionRoot = runtimeRoot.appendingPathComponent(descriptor.version, isDirectory: true)
        let location = CEFRuntimeLocation(
            versionRoot: versionRoot,
            frameworksDirectory: versionRoot.appendingPathComponent("Frameworks", isDirectory: true)
        )
        return location.isUsable ? location : nil
    }

    static func bundledLocation(bundle: Bundle = .main) -> CEFRuntimeLocation? {
        let frameworksDirectory = bundle.bundleURL
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let location = CEFRuntimeLocation(
            versionRoot: bundle.bundleURL,
            frameworksDirectory: frameworksDirectory
        )
        return location.isUsable ? location : nil
    }

    static func resolvedLocation() -> CEFRuntimeLocation? {
        installedLocation() ?? bundledLocation()
    }
}
