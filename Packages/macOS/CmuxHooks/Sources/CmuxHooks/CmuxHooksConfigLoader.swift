import CmuxSettings
public import Foundation

/// Loads the `hooks` section from the cmux JSONC configuration file.
public struct CmuxHooksConfigLoader: Sendable {
    private let sanitizer: JSONCSanitizer
    private let decoder: JSONDecoder

    /// Creates a hooks config loader.
    public init() {
        self.sanitizer = JSONCSanitizer()
        self.decoder = JSONDecoder()
    }

    /// Loads hook configuration from `fileURL`.
    /// - Parameter fileURL: The global cmux config file URL.
    /// - Returns: The decoded hook state, including fail-closed `.broken` when hooks are present but invalid.
    public func load(fileURL: URL) -> CmuxHooksConfigState {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return .absent
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .broken(reason: "failed to read hooks configuration: \(error)")
        }
        do {
            let sanitized = try sanitizer.sanitize(data)
            let root = try decoder.decode(HooksRoot.self, from: sanitized)
            guard let hooks = root.hooks else { return .absent }
            return .loaded(hooks)
        } catch {
            if textuallyContainsHooks(data) {
                return .broken(reason: String(describing: error))
            }
            return .absent
        }
    }

    private struct HooksRoot: Decodable {
        let hooks: CmuxHooksConfig?
    }

    private func textuallyContainsHooks(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf32) else {
            return false
        }
        return text.contains("\"hooks\"")
    }
}
