public import AppKit
import CmuxNextDesign

/// A project's badge in the Recents filter (Leo, T3 Code ref): its folder
/// name's first and last letters on a tint, in a color that stays the same
/// for the same folder name.
public nonisolated struct SidebarProjectBadge: Hashable, Sendable {
    /// The badge tints, picked by a stable hash of the folder name.
    public static var palette: [NSColor] {
        [.systemYellow, .systemBlue, .systemGreen, .systemPurple, .systemOrange, .systemPink, .systemTeal, .systemRed]
    }

    public var path: String
    /// The folder name.
    public var name: String
    public var letters: String
    public var colorIndex: Int

    public init(path: String) {
        self.path = path
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        name = (trimmed as NSString).lastPathComponent
        let characters = name.filter { $0.isLetter || $0.isNumber }
        if let first = characters.first, let last = characters.last {
            letters = (characters.count > 1 ? "\(first)\(last)" : "\(first)").uppercased()
        } else {
            letters = "?"
        }
        // FNV-1a: Swift's own hash is seeded per launch.
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        colorIndex = Int(hash % UInt32(Self.palette.count))
    }

    /// The badge drawn `height` points tall: the letters in the project's
    /// color on a faint fill of it.
    @MainActor public func image(height: CGFloat = 16) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: (height * 0.56).rounded(), weight: .bold)
        let color = Self.palette[colorIndex]
        let text = NSAttributedString(string: letters, attributes: [.font: font, .foregroundColor: color])
        let size = NSSize(width: max(height, (text.size().width + height * 0.4).rounded(.up)), height: height)
        return NSImage(size: size, flipped: false) { rect in
            color.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: rect, xRadius: height * 0.22, yRadius: height * 0.22).fill()
            let textSize = text.size()
            text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            return true
        }
    }
}
