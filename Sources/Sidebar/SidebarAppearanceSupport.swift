import AppKit
import Foundation
import SwiftUI

enum SidebarMatchTerminalBackgroundSettings {
    static let userDefaultsKey = "sidebarMatchTerminalBackground"
    static let legacyAppliedSettingsFileDefaultKey = "cmux.settingsFile.sidebarMatchTerminalBackground.appliedDefault.v1"
}

enum SidebarWorkspaceIconSettings {
    static let autoDetectKey = "sidebarAutoDetectWorkspaceIcon"
    static let defaultAutoDetect = false

    static func autoDetectsWorkspaceIcon(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: autoDetectKey) != nil else { return defaultAutoDetect }
        return defaults.bool(forKey: autoDetectKey)
    }
}

enum WorkspaceIconValue: Equatable, Sendable {
    case emoji(String)
    case file(path: String)

    init?(storedValue: String?) {
        guard let storedValue = Self.normalizedStorageValue(storedValue) else { return nil }
        if storedValue.hasPrefix(Self.emojiPrefix) {
            let emoji = String(storedValue.dropFirst(Self.emojiPrefix.count))
            guard !emoji.isEmpty else { return nil }
            self = .emoji(emoji)
        } else {
            self = .file(path: storedValue)
        }
    }

    var storageValue: String {
        switch self {
        case .emoji(let emoji):
            return Self.emojiPrefix + emoji
        case .file(let path):
            return path
        }
    }

    static func normalizedStorageValue(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix(Self.emojiPrefix) {
            let emoji = String(trimmed.dropFirst(Self.emojiPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !emoji.isEmpty, emoji.allSatisfy(Self.isEmojiCluster) else { return nil }
            return Self.emojiPrefix + emoji
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let standardized = NSString(string: expanded).standardizingPath
        let normalized = standardized.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static let emojiPrefix = "emoji:"

    private static func isEmojiCluster(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F
        }
    }
}

enum WorkspaceIconDetector {
    static let standardIconFilenames = [
        "favicon.png", "favicon.jpg", "favicon.jpeg",
        "icon.png", "icon.jpg", "icon.jpeg",
        "logo.png", "logo.jpg", "logo.jpeg",
    ]

    static let standardIconSubdirectories = [
        "",
        "public",
        "static",
        "src",
        "assets",
        "images",
        "Resources",
        ".github",
        "docs",
    ]

    static func detectedIconPath(in directory: String) -> String? {
        let normalizedDirectory = WorkspaceIconValue.normalizedStorageValue(directory)
        guard let normalizedDirectory else { return nil }

        let fileManager = FileManager.default
        if let standardIcon = findStandardIcon(in: normalizedDirectory, fileManager: fileManager) {
            return standardIcon
        }
        if let appIcon = findXcodeAppIcon(in: normalizedDirectory, fileManager: fileManager) {
            return appIcon
        }
        if let androidIcon = findFirstExistingPath(
            in: normalizedDirectory,
            relativePaths: [
                "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
                "android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png",
                "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
                "app/src/main/res/mipmap-xxhdpi/ic_launcher.png",
            ],
            fileManager: fileManager
        ) {
            return androidIcon
        }
        return findFirstExistingPath(
            in: normalizedDirectory,
            relativePaths: [
                "build/icon.png",
                "build/icons/icon.png",
                "resources/icon.png",
            ],
            fileManager: fileManager
        )
    }

    private static func findStandardIcon(in directory: String, fileManager: FileManager) -> String? {
        for subdirectory in standardIconSubdirectories {
            let basePath = subdirectory.isEmpty
                ? directory
                : (directory as NSString).appendingPathComponent(subdirectory)
            for filename in standardIconFilenames {
                guard !Task.isCancelled else { return nil }
                let path = (basePath as NSString).appendingPathComponent(filename)
                if fileManager.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    private static func findXcodeAppIcon(in directory: String, fileManager: FileManager) -> String? {
        for candidate in [
            "Assets.xcassets/AppIcon.appiconset",
            "Resources/Assets.xcassets/AppIcon.appiconset",
        ] {
            let iconsetPath = (directory as NSString).appendingPathComponent(candidate)
            guard let contents = try? fileManager.contentsOfDirectory(atPath: iconsetPath) else {
                continue
            }
            guard !Task.isCancelled else { return nil }
            let pngs = contents
                .filter { $0.lowercased().hasSuffix(".png") }
                .sorted { lhs, rhs in
                    fileSize(at: (iconsetPath as NSString).appendingPathComponent(lhs), fileManager: fileManager)
                        > fileSize(at: (iconsetPath as NSString).appendingPathComponent(rhs), fileManager: fileManager)
                }
            if let largest = pngs.first {
                return (iconsetPath as NSString).appendingPathComponent(largest)
            }
        }
        return nil
    }

    private static func findFirstExistingPath(
        in directory: String,
        relativePaths: [String],
        fileManager: FileManager
    ) -> String? {
        for relativePath in relativePaths {
            guard !Task.isCancelled else { return nil }
            let path = (directory as NSString).appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func fileSize(at path: String, fileManager: FileManager) -> UInt64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }
}

struct WorkspaceIconFileSignature: Equatable, Sendable {
    let modificationTime: TimeInterval
    let size: UInt64

    static func current(for path: String, fileManager: FileManager = .default) -> Self? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return Self(modificationTime: modificationTime, size: size)
    }
}

struct WorkspaceIconDetectionResult: Equatable, Sendable {
    let path: String?
    let signature: WorkspaceIconFileSignature?

    static func detect(in directory: String) -> Self {
        let path = WorkspaceIconDetector.detectedIconPath(in: directory)
        return Self(path: path, signature: path.flatMap { WorkspaceIconFileSignature.current(for: $0) })
    }
}

struct WorkspaceIconView: View {
    let iconPath: String
    let reloadToken: String?
    let size: CGFloat

    @State private var loadedImage: NSImage?
    @State private var loadedImagePath: String?
    @State private var imageLoadFailed = false

    private var iconValue: WorkspaceIconValue? {
        WorkspaceIconValue(storedValue: iconPath)
    }

    var body: some View {
        ZStack {
            switch iconValue {
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: size * 0.55))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.primary.opacity(0.08)))

            case .file(let path):
                if loadedImagePath == path, let loadedImage {
                    Image(nsImage: loadedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                } else {
                    placeholderIcon
                }

            case nil:
                placeholderIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: iconLoadKey) {
            await loadFileIconIfNeeded()
        }
    }

    private var iconLoadKey: String {
        "\(iconPath)\u{0}\(reloadToken ?? "")"
    }

    @ViewBuilder
    private var placeholderIcon: some View {
        Image(systemName: imageLoadFailed ? "exclamationmark.triangle" : "photo")
            .font(.system(size: size * 0.36, weight: .medium))
            .foregroundColor(.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(0.06)))
    }

    @MainActor
    private func loadFileIconIfNeeded() async {
        guard case .file(let path) = iconValue else {
            loadedImage = nil
            loadedImagePath = nil
            imageLoadFailed = false
            return
        }

        loadedImage = nil
        loadedImagePath = path
        imageLoadFailed = false

        let imageData = await Task.detached(priority: .utility) {
            try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        }.value

        guard !Task.isCancelled, loadedImagePath == path else { return }
        loadedImage = imageData.flatMap(NSImage.init(data:))
        imageLoadFailed = loadedImage == nil
    }
}

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8)  & 0xFF) / 255.0,
            blue:  Double( value        & 0xFF) / 255.0
        )
    }
}

func coloredCircleImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 14, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    image.isTemplate = false
    return image
}

func sidebarActiveForegroundNSColor(
    opacity: CGFloat,
    appAppearance: NSAppearance? = NSApp?.effectiveAppearance
) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let baseColor: NSColor = (bestMatch == .darkAqua) ? .white : .black
    return baseColor.withAlphaComponent(clampedOpacity)
}

func cmuxAccentNSColor(for colorScheme: ColorScheme) -> NSColor {
    switch colorScheme {
    case .dark:
        return NSColor(
            srgbRed: 0,
            green: 145.0 / 255.0,
            blue: 1.0,
            alpha: 1.0
        )
    default:
        return NSColor(
            srgbRed: 0,
            green: 136.0 / 255.0,
            blue: 1.0,
            alpha: 1.0
        )
    }
}

func cmuxAccentNSColor(for appAppearance: NSAppearance?) -> NSColor {
    let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let scheme: ColorScheme = (bestMatch == .darkAqua) ? .dark : .light
    return cmuxAccentNSColor(for: scheme)
}

func cmuxAccentNSColor() -> NSColor {
    NSColor(name: nil) { appearance in
        cmuxAccentNSColor(for: appearance)
    }
}

func cmuxAccentColor() -> Color {
    Color(nsColor: cmuxAccentNSColor())
}

struct SidebarRemoteErrorCopyEntry: Equatable {
    let workspaceTitle: String
    let target: String
    let detail: String
}

enum SidebarRemoteErrorCopySupport {
    static func menuLabel(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1 {
            return String(localized: "contextMenu.copyError", defaultValue: "Copy Error")
        }
        return String(localized: "contextMenu.copyErrors", defaultValue: "Copy Errors")
    }

    static func clipboardText(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1, let entry = entries.first {
            return String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.single", defaultValue: "SSH error (%@): %@"),
                entry.target,
                entry.detail
            )
        }

        return entries.enumerated().map { index, entry in
            String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.item", defaultValue: "%lld. %@ (%@): %@"),
                Int64(index + 1),
                entry.workspaceTitle,
                entry.target,
                entry.detail
            )
        }.joined(separator: "\n")
    }
}

func sidebarSelectedWorkspaceBackgroundNSColor(
    for colorScheme: ColorScheme,
    sidebarSelectionColorHex: String? = UserDefaults.standard.string(forKey: "sidebarSelectionColorHex")
) -> NSColor {
    if let hex = sidebarSelectionColorHex,
       let parsed = NSColor(hex: hex) {
        return parsed
    }
    return cmuxAccentNSColor(for: colorScheme)
}

func sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    return NSColor.white.withAlphaComponent(clampedOpacity)
}

struct SidebarWorkspaceRowBackgroundStyle {
    let color: NSColor?
    let opacity: Double

    static let clear = Self(color: nil, opacity: 0)
}

func sidebarWorkspaceRowExplicitRailNSColor(
    activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle,
    customColorHex: String?,
    colorScheme: ColorScheme
) -> NSColor? {
    guard activeTabIndicatorStyle == .leftRail,
          let customColorHex else {
        return nil
    }
    return WorkspaceTabColorSettings.displayNSColor(
        hex: customColorHex,
        colorScheme: colorScheme,
        forceBright: true
    )
}

func sidebarWorkspaceRowBackgroundStyle(
    activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle,
    isActive: Bool,
    isMultiSelected: Bool,
    customColorHex: String?,
    colorScheme: ColorScheme,
    sidebarSelectionColorHex: String?
) -> SidebarWorkspaceRowBackgroundStyle {
    let selectedBackground = sidebarSelectedWorkspaceBackgroundNSColor(
        for: colorScheme,
        sidebarSelectionColorHex: sidebarSelectionColorHex
    )
    let accentBackground = cmuxAccentNSColor(for: colorScheme)
    let customBackground = customColorHex.flatMap {
        WorkspaceTabColorSettings.displayNSColor(
            hex: $0,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        )
    }

    switch activeTabIndicatorStyle {
    case .leftRail:
        if isActive {
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: 1
            )
        }
        if isMultiSelected {
            return SidebarWorkspaceRowBackgroundStyle(color: accentBackground, opacity: 0.25)
        }
        return .clear

    case .solidFill:
        if isActive {
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: 1
            )
        }
        if let customBackground {
            return SidebarWorkspaceRowBackgroundStyle(
                color: customBackground,
                opacity: isMultiSelected ? 0.35 : 0.7
            )
        }
        if isMultiSelected {
            return SidebarWorkspaceRowBackgroundStyle(color: accentBackground, opacity: 0.25)
        }
        return .clear
    }
}
