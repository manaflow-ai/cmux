public import Foundation

extension Bundle {
    /// The SwiftPM resource bundle (`CmuxNext_<Module>.bundle`) of the CmuxNext target that compiles
    /// `anchor`, found without SwiftPM's generated `Bundle.module`, from any isolation.
    ///
    /// `Bundle.module` takes its target's default isolation on some toolchains: SwiftPM writes it
    /// without `nonisolated`, so in a `.defaultIsolation(MainActor.self)` target Xcode 27 makes it
    /// main-actor isolated and a nonisolated read of it does not compile ("main actor-isolated
    /// static property 'module' can not be referenced from a nonisolated context"), while Xcode 26
    /// and Linux accept the same line. This looks in the places `Bundle.module` and CmuxNextDesign's
    /// `ModuleResourceBundle` look (the app's resources, beside the code, beside a `swift test`
    /// bundle); with none there it answers the main bundle instead of trapping, so localized text
    /// falls back to its English source string.
    public nonisolated static func cmuxNextModuleResources(anchor: AnyClass) -> Bundle {
        let module = String(reflecting: anchor).prefix { $0 != "." }
        let name = "CmuxNext_\(module).bundle"
        let code = Bundle(for: anchor)
        let directories = [
            Bundle.main.resourceURL,
            code.resourceURL,
            Bundle.main.bundleURL,
            // `swift test` puts module bundles beside the .xctest bundle.
            code.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }
        return directories.lazy
            .compactMap { Bundle(url: $0.appending(path: name, directoryHint: .isDirectory)) }
            .first ?? .main
    }
}
