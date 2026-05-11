import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceIconPrompting {
    static func promptSymbol(apply: (CmuxButtonIcon) -> Void) {
        promptText(
            title: String(localized: "alert.workspaceIcon.symbol.title", defaultValue: "Set Workspace Symbol"),
            message: String(localized: "alert.workspaceIcon.symbol.message", defaultValue: "Enter an SF Symbol name."),
            placeholder: "folder.fill",
            makeIcon: { .symbol($0) },
            apply: apply
        )
    }

    static func promptEmoji(apply: (CmuxButtonIcon) -> Void) {
        promptText(
            title: String(localized: "alert.workspaceIcon.emoji.title", defaultValue: "Set Workspace Emoji"),
            message: String(localized: "alert.workspaceIcon.emoji.message", defaultValue: "Enter an emoji or short glyph."),
            placeholder: "🚀",
            makeIcon: { .emoji($0, scale: 1) },
            apply: apply
        )
    }

    static func promptImage(apply: (CmuxButtonIcon) -> Void) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "panel.workspaceIcon.image.title", defaultValue: "Choose Workspace Icon")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType.image,
            UTType(filenameExtension: "svg"),
            UTType(filenameExtension: "ico"),
        ].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        apply(.imagePath(url.path))
    }

    private static func promptText(
        title: String,
        message: String,
        placeholder: String,
        makeIcon: (String) -> CmuxButtonIcon,
        apply: (CmuxButtonIcon) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message

        let input = NSTextField(string: "")
        input.placeholderString = placeholder
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.workspaceIcon.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.workspaceIcon.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showInvalidWorkspaceIconAlert()
            return
        }
        apply(makeIcon(trimmed))
    }

    private static func showInvalidWorkspaceIconAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.workspaceIcon.invalid.title", defaultValue: "Invalid Workspace Icon")
        alert.informativeText = String(localized: "alert.workspaceIcon.invalid.message", defaultValue: "Enter a non-empty symbol name, emoji, or image path.")
        alert.addButton(withTitle: String(localized: "alert.workspaceIcon.invalid.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }
}

private enum SidebarWorkspaceIconImageCache {
    private struct FileMetadata: Sendable {
        let cacheKey: String
    }

    @MainActor
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func cachedImage(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    @MainActor
    static func store(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: cacheCost(for: image))
    }

    nonisolated static func metadata(forExpandedPath expandedPath: String) async -> String {
        await Task.detached(priority: .utility) {
            FileMetadata(cacheKey: cacheKey(forExpandedPath: expandedPath))
        }.value.cacheKey
    }

    nonisolated static func fileData(forExpandedPath expandedPath: String) async -> Data? {
        await Task.detached(priority: .utility) {
            try? Data(contentsOf: URL(fileURLWithPath: expandedPath, isDirectory: false))
        }.value
    }

    nonisolated private static func cacheKey(forExpandedPath expandedPath: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: expandedPath)
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let byteSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        return "\(expandedPath)|\(modifiedAt)|\(byteSize)"
    }

    @MainActor
    private static func cacheCost(for image: NSImage) -> Int {
        let pixels = max(1, Int(image.size.width * image.size.height))
        return pixels * 4
    }
}

@MainActor
private final class SidebarWorkspaceIconImageLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var didLoad = false

    private var requestedPath: String?
    private var isLoading = false
    private var loadTask: Task<Void, Never>?

    func load(path: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard requestedPath != expandedPath || (!didLoad && !isLoading) else { return }
        requestedPath = expandedPath
        image = nil
        didLoad = false
        isLoading = true
        loadTask?.cancel()

        loadTask = Task { [weak self, expandedPath] in
            let cacheKey = await SidebarWorkspaceIconImageCache.metadata(forExpandedPath: expandedPath)
            guard !Task.isCancelled else { return }

            if let cached = SidebarWorkspaceIconImageCache.cachedImage(forKey: cacheKey) {
                guard let self, self.requestedPath == expandedPath else { return }
                self.image = cached
                self.didLoad = true
                self.isLoading = false
                return
            }

            let data = await SidebarWorkspaceIconImageCache.fileData(forExpandedPath: expandedPath)
            guard !Task.isCancelled else { return }

            let loadedImage = data.flatMap(NSImage.init(data:))
            if let loadedImage {
                SidebarWorkspaceIconImageCache.store(loadedImage, forKey: cacheKey)
            }
            guard let self, self.requestedPath == expandedPath else { return }
            self.image = loadedImage
            self.didLoad = true
            self.isLoading = false
        }
    }
}

struct SidebarWorkspaceIconView: View {
    private static let frameSize: CGFloat = 14

    let icon: CmuxButtonIcon
    let foregroundColor: Color

    @StateObject private var imageLoader = SidebarWorkspaceIconImageLoader()

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(foregroundColor)
            case .emoji(let value, let scale):
                Text(value)
                    .font(.system(size: CGFloat(max(8, 12 * scale))))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            case .imagePath(let path):
                imageContent(path: path)
            }
        }
        .frame(width: Self.frameSize, height: Self.frameSize, alignment: .center)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func imageContent(path: String) -> some View {
        Group {
            if let image = imageLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(foregroundColor)
                    .opacity(imageLoader.didLoad ? 1 : 0.45)
            }
        }
        .onAppear {
            imageLoader.load(path: path)
        }
        .onChange(of: path) { _, newPath in
            imageLoader.load(path: newPath)
        }
    }
}
