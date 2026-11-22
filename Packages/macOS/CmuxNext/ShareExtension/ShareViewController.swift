// The Share extension (Share menu > "<app> Chat"), built into Contents/PlugIns/CmuxShare.appex by
// scripts/cmux-next/bundle-share-extension.sh. It holds no product logic: it opens the shared image
// files with the app that carries it, the same door as an image opened with cmux or dropped on its
// Dock icon (ExternalOpenRoute's attachImages, AgentPaneExternalAttach), which puts them in a chat
// composer as an unsent draft. There is no sheet: the request ends as soon as the app has the files,
// so a script can perform it (NSSharingService.perform) and the person goes straight to the chat.
import AppKit
import UniformTypeIdentifiers
import os

@objc(CmuxShareViewController)
final class ShareViewController: NSViewController {
    // Each step of the handoff, under the extension's own bundle id: a share that never reaches the app says
    // where it stopped (`log show --predicate 'subsystem == "<extension id>"'`).
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CmuxShare", category: "handoff")

    override func loadView() {
        Self.log.notice("loadView")
        view = NSView(frame: .zero)
    }

    /// A picture shared as bytes, not a file (Photos, a browser): written to this extension's own
    /// temporary folder, which the app (not sandboxed) reads like any other opened file.
    private static func saved(_ data: Data) -> URL? {
        let jpeg = data.starts(with: [0xFF, 0xD8, 0xFF])
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        guard let bytes = jpeg || data.starts(with: png)
            ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shared \(UUID().uuidString).\(jpeg ? "jpg" : "png")")
        return (try? bytes.write(to: url)) == nil ? nil : url
    }

    override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
        let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Self.log.notice("beginRequest: \(providers.count, privacy: .public) attachment(s)")
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, URL)] = []
        for (index, provider) in providers.enumerated() {
            guard let type = [UTType.fileURL, UTType.image].map(\.identifier)
                .first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                Self.log.notice("loadItem \(type, privacy: .public): \(String(describing: Swift.type(of: item)), privacy: .public) error \(String(describing: error), privacy: .public)")
                var url = item as? URL
                if url == nil, let data = item as? Data {
                    url = type == UTType.fileURL.identifier
                        ? URL(dataRepresentation: data, relativeTo: nil) : Self.saved(data)
                } else if url == nil, let image = item as? NSImage {
                    url = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
                        .flatMap { $0.representation(using: .png, properties: [:]) }.flatMap(Self.saved)
                }
                if let url, url.isFileURL {
                    lock.lock()
                    found.append((index, url))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = found.sorted { $0.0 < $1.0 }.map(\.1)
            Self.log.notice("opening \(urls.count, privacy: .public) file(s)")
            guard !urls.isEmpty else {
                context.cancelRequest(withError: CocoaError(.fileReadNoSuchFile))
                return
            }
            // Contents/PlugIns/CmuxShare.appex -> the .app that carries it, never another copy.
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            Self.log.notice("open with \(app.path, privacy: .public)")
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    Self.log.notice("open answered: \(String(describing: error), privacy: .public)")
                    if let error {
                        context.cancelRequest(withError: error)
                    } else {
                        context.completeRequest(returningItems: nil)
                    }
                }
            }
        }
    }
}
