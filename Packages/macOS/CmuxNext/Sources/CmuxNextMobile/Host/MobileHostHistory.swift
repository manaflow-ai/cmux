public import Foundation

/// Whether this Mac's phone host ran before: it then holds a v2 cache under
/// its state directory (`V2FileStateStore` writes `cmux-iroh-v2/state/*.sealed`,
/// or a legacy `.json`, once the Mac is registered for an account).
/// The cache is encrypted, so this does not say which phones connected; it
/// says the Mac served phones under the old always-on behavior. Iroh-specific
/// like the rest of `Host/`.
public struct MobileHostHistory: Sendable {
    public let stateDirectory: URL

    public init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory
    }

    public var servedPhones: Bool {
        let state = stateDirectory.appendingPathComponent("cmux-iroh-v2", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: state.path)) ?? []
        return files.contains { $0.hasSuffix(".sealed") || $0.hasSuffix(".json") }
    }
}
