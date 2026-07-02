import CmuxGit
import Foundation

extension WorkspaceTabColorSettings {
    static func resolvedColorHex(_ raw: String, defaults: UserDefaults = .standard) -> String? {
        if let normalized = normalizedHex(raw) {
            return normalized
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return resolvedPaletteMap(defaults: defaults)
            .first { name, _ in name.caseInsensitiveCompare(trimmed) == .orderedSame }?
            .value
    }

    static func paletteCacheFingerprint(defaults: UserDefaults = .standard) -> String {
        resolvedPaletteMap(defaults: defaults)
            .sorted { lhs, rhs in lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    static func autoColorHex(forWorkingDirectory directory: String?) -> String? {
        guard let seed = autoColorSeed(forWorkingDirectory: directory) else {
            return nil
        }
        return autoColorHex(forSeed: seed)
    }

    static func autoColorSeed(forWorkingDirectory directory: String?) -> String? {
        guard let normalizedDirectory = normalizedAutoColorDirectory(directory) else {
            return nil
        }

        if let repository = GitMetadataService.resolveGitRepository(containing: normalizedDirectory) {
            if let remoteOutput = GitMetadataService.gitRemoteVOutput(repository: repository),
               let slug = GitMetadataService.githubRepositorySlugs(fromGitRemoteVOutput: remoteOutput).first {
                return "github:\(slug.lowercased())"
            }
            return "git:\(normalizedAutoColorPath(repository.workTreeRoot))"
        }

        return "path:\(normalizedAutoColorPath(normalizedDirectory))"
    }

    static func autoColorHex(forSeed seed: String) -> String {
        let hash = stableAutoColorHash(seed)
        let hue = Double(hash % 3_600) / 10.0
        let saturation = 0.54 + (Double((hash >> 16) % 12) / 100.0)
        let lightness = 0.58 + (Double((hash >> 32) % 10) / 100.0)
        let rgb = rgbFromHSL(hue: hue, saturation: saturation, lightness: lightness)
        return String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
    }

    private static func normalizedAutoColorDirectory(_ directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
            return normalizedAutoColorPath(url.path)
        }
        return normalizedAutoColorPath(trimmed)
    }

    private static func normalizedAutoColorPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func stableAutoColorHash(_ seed: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func rgbFromHSL(
        hue: Double,
        saturation: Double,
        lightness: Double
    ) -> (red: Int, green: Int, blue: Int) {
        let chroma = (1 - abs((2 * lightness) - 1)) * saturation
        let normalizedHue = hue / 60.0
        let x = chroma * (1 - abs(normalizedHue.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - (chroma / 2)

        let prime: (red: Double, green: Double, blue: Double)
        switch normalizedHue {
        case 0..<1:
            prime = (chroma, x, 0)
        case 1..<2:
            prime = (x, chroma, 0)
        case 2..<3:
            prime = (0, chroma, x)
        case 3..<4:
            prime = (0, x, chroma)
        case 4..<5:
            prime = (x, 0, chroma)
        default:
            prime = (chroma, 0, x)
        }

        return (
            red: clampedRGBComponent(prime.red + m),
            green: clampedRGBComponent(prime.green + m),
            blue: clampedRGBComponent(prime.blue + m)
        )
    }

    private static func clampedRGBComponent(_ value: Double) -> Int {
        Int((min(1, max(0, value)) * 255).rounded())
    }
}
