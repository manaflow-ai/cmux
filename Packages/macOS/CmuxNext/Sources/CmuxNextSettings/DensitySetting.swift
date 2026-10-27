public import CmuxNextDesignTokens
import Foundation

/// `appearance.density` in cmux.json: a built-in density's id (``DensityPreset``) or the id of
/// one of the file's `appearance.customDensities` (plans/cmux-next/density-DESIGN.md).
public nonisolated struct DensitySetting: Sendable {
    /// The key's path.
    public let configPath = ["appearance", "density"]
    /// The density when the key is absent or names no density.
    public let fallback = DensityPreset.compact.rawValue

    public init() {}

    /// Whether `id` can name a density: a built-in, or 1 to 64 lowercase letters, digits and
    /// hyphens (a custom density's id).
    public static func isValidID(_ id: String) -> Bool {
        if DensityPreset(rawValue: id) != nil { return true }
        guard (1...64).contains(id.count), id.first != "-" else { return false }
        return id.allSatisfy { ($0.isLetter && $0.isLowercase || $0.isNumber) && $0.isASCII || $0 == "-" }
    }

    /// The density `id` names among the built-ins and `custom`; nil when none has it.
    public static func resolve(_ id: String?, custom: [DensityTokens]) -> DensityTokens? {
        guard let id else { return nil }
        return DensityPreset(rawValue: id)?.tokens ?? custom.first { $0.id == id }
    }
}
