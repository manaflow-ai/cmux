import AppKit

/// Resolves VS Code-style Material file icons from the bundled icon set.
///
/// The mapping (`material-icons.json`) and the SVGs (`Resources/MaterialIcons`)
/// are the Material Icon Theme's: file names beat extensions, and compound
/// extensions match longest-first ("foo.test.tsx" tries "test.tsx" before
/// "tsx"). Resolution is cached per icon and point size; a name with no SVG is
/// remembered so the file system is only consulted once per icon.
final class MaterialFileIconResolver {
    static let shared = MaterialFileIconResolver()

    private struct Mapping: Decodable {
        let file: String
        let folder: String
        let folderExpanded: String?
        let fileExtensions: [String: String]
        let fileNames: [String: String]
        let folderNames: [String: String]
        let folderNamesExpanded: [String: String]?
    }

    private let mapping: Mapping?
    private let iconsDirectory: URL?
    private let imageCache = NSCache<NSString, NSImage>()
    private var missing = Set<String>()

    private init() {
        if let url = Bundle.main.url(forResource: "material-icons", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Mapping.self, from: data) {
            mapping = decoded
        } else {
            mapping = nil
        }
        iconsDirectory = Bundle.main.resourceURL?
            .appendingPathComponent("MaterialIcons", isDirectory: true)
    }

    var isAvailable: Bool { mapping != nil && iconsDirectory != nil }

    /// Resolved, cached, colored icon (or nil when the set isn't bundled).
    func image(name: String, isDirectory: Bool, pointSize: CGFloat) -> NSImage? {
        guard let mapping, isAvailable else { return nil }
        let resolvedName = isDirectory
            ? iconName(forFolderName: name, mapping: mapping)
            : iconName(forFileName: name, mapping: mapping)
        return image(named: resolvedName, pointSize: pointSize)
            ?? image(named: isDirectory ? mapping.folder : mapping.file, pointSize: pointSize)
    }

    private func iconName(forFileName name: String, mapping: Mapping) -> String {
        let lower = name.lowercased()
        if let icon = mapping.fileNames[lower] { return icon }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1 {
            for index in 1..<parts.count {
                let ext = parts[index...].joined(separator: ".")
                if let icon = mapping.fileExtensions[ext] { return icon }
            }
        }
        return mapping.file
    }

    private func iconName(forFolderName name: String, mapping: Mapping) -> String {
        if let icon = mapping.folderNames[name.lowercased()] { return icon }
        return mapping.folder
    }

    private func image(named iconName: String, pointSize: CGFloat) -> NSImage? {
        guard let iconsDirectory, !missing.contains(iconName) else { return nil }
        let key = "\(iconName)#\(Int(pointSize))" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let url = iconsDirectory.appendingPathComponent(iconName + ".svg")
        guard let image = NSImage(contentsOf: url) else {
            missing.insert(iconName)
            return nil
        }
        image.isTemplate = false
        image.size = NSSize(width: pointSize, height: pointSize)
        imageCache.setObject(image, forKey: key)
        return image
    }
}
