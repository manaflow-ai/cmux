import AppKit
import CmuxAppKitSupportUI
import UniformTypeIdentifiers

/// Renders each Files row icon once per kind, style and appearance.
///
/// Rows share a handful of icons (folder, one per file type). Rendering the
/// tinted icon on every cell reuse cost a bitmap draw per scrolled row; the
/// cache turns scrolling a 50,000-row folder into image lookups.
@MainActor
final class FileExplorerIconCache {
    private struct Key: Hashable {
        let style: Int
        let kind: String
        let appearance: String
        let size: CGFloat
    }

    private let renderer = CmuxResolvedIconRenderer()
    private var images: [Key: NSImage] = [:]
    private var typeByExtension: [String: UTType] = [:]
    private let capacity = 512

    /// The icon for `node` in `style` under `appearance`.
    func icon(for node: FileExplorerNode, style: FileExplorerStyle, appearance: NSAppearance) -> NSImage? {
        let kind = kindKey(for: node, style: style)
        let appearanceName = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])?.rawValue ?? appearance.name.rawValue
        let key = Key(style: style.rawValue, kind: kind, appearance: appearanceName, size: style.iconSize)
        if let cached = images[key] { return cached }
        let request = self.request(for: node, kind: kind, style: style)
        guard let image = renderer.image(for: request, appearance: appearance) else { return nil }
        if images.count >= capacity { images.removeAll(keepingCapacity: true) }
        images[key] = image
        return image
    }

    private func kindKey(for node: FileExplorerNode, style: FileExplorerStyle) -> String {
        let ext = node.entry.pathExtension
        if node.isDirectory {
            guard style == .finder, !ext.isEmpty, packageType(forExtension: ext) != nil else { return "folder" }
            return "package:" + ext
        }
        guard style == .finder else { return "file" }
        return ext.isEmpty ? "file" : "ext:" + ext
    }

    private func packageType(forExtension ext: String) -> UTType? {
        guard let type = contentType(forExtension: ext), type.conforms(to: .package) else { return nil }
        return type
    }

    private func contentType(forExtension ext: String) -> UTType? {
        if let cached = typeByExtension[ext] { return cached }
        let type = UTType(filenameExtension: ext)
        if let type { typeByExtension[ext] = type }
        return type
    }

    private func request(for node: FileExplorerNode, kind: String, style: FileExplorerStyle) -> CmuxResolvedIconRequest {
        let size = NSSize(width: style.iconSize, height: style.iconSize)
        if style == .finder {
            // Native Finder icon pixels miss 3:1 in light mode; use their masks with the dynamic palette tint.
            let type: UTType
            if node.isDirectory {
                type = packageType(forExtension: node.entry.pathExtension) ?? .folder
            } else {
                type = contentType(forExtension: node.entry.pathExtension) ?? .data
            }
            return CmuxResolvedIconRequest(
                source: .image(NSWorkspace.shared.icon(for: type)),
                size: size,
                tintColor: node.isDirectory ? style.folderIconTint : style.fileIconTint
            )
        }
        return CmuxResolvedIconRequest(
            source: .systemSymbol(name: node.isDirectory ? "folder.fill" : "doc", accessibilityDescription: nil),
            size: size,
            tintColor: node.isDirectory ? style.folderIconTint : style.fileIconTint,
            symbolWeight: style.iconWeight
        )
    }
}
