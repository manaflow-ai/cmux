import AppKit
import Foundation
import SwiftUI

extension SessionAgent {
    var displayName: String {
        switch self {
        case .claude: return String(localized: "sessionIndex.agent.claude", defaultValue: "Claude Code")
        case .codex: return String(localized: "sessionIndex.agent.codex", defaultValue: "Codex")
        case .grok: return String(localized: "sessionIndex.agent.grok", defaultValue: "Grok")
        case .opencode: return String(localized: "sessionIndex.agent.opencode", defaultValue: "OpenCode")
        case .rovodev: return String(localized: "sessionIndex.agent.rovodev", defaultValue: "Rovo Dev")
        case .registered(let agent):
            return agent.displayName
        case .hermesAgent: return String(localized: "sessionIndex.agent.hermesAgent", defaultValue: "Hermes Agent")
        }
    }

    /// Asset catalog image name for the agent's brand mark.
    var assetName: String? {
        switch self {
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .grok: return "AgentIcons/Grok"
        case .opencode: return "AgentIcons/OpenCode"
        case .rovodev: return "AgentIcons/RovoDev"
        case .registered(let agent):
            return agent.iconAssetName
        case .hermesAgent: return "AgentIcons/HermesAgent"
        }
    }

    var systemImageName: String? {
        switch self {
        case .registered:
            return assetName == nil ? "person.crop.circle" : nil
        default:
            return nil
        }
    }
}

private final class AgentAssetIconCache {
    static let shared = AgentAssetIconCache()
    private static let maxCachedImages = 96

    private struct Key: Hashable {
        let assetName: String
        let pixelSize: Int
        let appearanceName: String
    }

    private var images: [Key: NSImage] = [:]
    private var insertionOrder: [Key] = []

    @MainActor
    func image(named assetName: String, pointSize: CGFloat, colorScheme: ColorScheme) -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelSize = max(1, Int((pointSize * scale).rounded(.up)))
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let key = Key(
            assetName: assetName,
            pixelSize: pixelSize,
            appearanceName: appearanceName.rawValue
        )
        if let cached = images[key] {
            return cached
        }
        guard let source = NSImage(named: NSImage.Name(assetName)) else {
            return nil
        }
        let image = Self.rasterizedImage(
            from: source,
            pointSize: pointSize,
            pixelSize: pixelSize,
            appearanceName: appearanceName
        )
        images[key] = image
        insertionOrder.append(key)
        trimCache()
        return image
    }

    private func trimCache() {
        while images.count > Self.maxCachedImages, !insertionOrder.isEmpty {
            let key = insertionOrder.removeFirst()
            images.removeValue(forKey: key)
        }
    }

    private static func rasterizedImage(
        from source: NSImage,
        pointSize: CGFloat,
        pixelSize: Int,
        appearanceName: NSAppearance.Name
    ) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            let fallback = source.copy() as? NSImage ?? source
            fallback.isTemplate = false
            return fallback
        }

        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            let fallback = source.copy() as? NSImage ?? source
            fallback.isTemplate = false
            return fallback
        }

        let draw = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: size).fill()
            source.draw(
                in: NSRect(origin: .zero, size: size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        if let appearance = NSAppearance(named: appearanceName) {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }
}

struct AgentAssetIconImage: View, Equatable {
    let assetName: String
    let size: CGFloat
    let fallbackSystemName: String
    let fallbackColor: Color
    let fallbackColorID: String

    @Environment(\.colorScheme) private var colorScheme

    init(
        assetName: String,
        size: CGFloat,
        fallbackSystemName: String,
        fallbackColor: Color = .secondary,
        fallbackColorID: String = "secondary"
    ) {
        self.assetName = assetName
        self.size = size
        self.fallbackSystemName = fallbackSystemName
        self.fallbackColor = fallbackColor
        self.fallbackColorID = fallbackColorID
    }

    static func == (lhs: AgentAssetIconImage, rhs: AgentAssetIconImage) -> Bool {
        lhs.assetName == rhs.assetName &&
            lhs.size == rhs.size &&
            lhs.fallbackSystemName == rhs.fallbackSystemName &&
            lhs.fallbackColorID == rhs.fallbackColorID
    }

    var body: some View {
        Group {
            if let image = AgentAssetIconCache.shared.image(
                named: assetName,
                pointSize: size,
                colorScheme: colorScheme
            ) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: max(size - 2, 10), weight: .regular))
                    .foregroundColor(fallbackColor)
            }
        }
        .frame(width: size, height: size)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
