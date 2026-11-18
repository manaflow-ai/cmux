// The Share extension (Share menu > "<app> Chat"), built into Contents/PlugIns/CmuxShare.appex by
// scripts/cmux-next/bundle-share-extension.sh. It holds no product logic: it opens the shared image
// files with the app that carries it, the same door as an image opened with cmux or dropped on its
// Dock icon (ExternalOpenRoute's attachImages, AgentPaneExternalAttach), which puts them in a chat
// composer as an unsent draft. There is no sheet: the request ends as soon as the app has the files,
// so a script can perform it (NSSharingService.perform) and the person goes straight to the chat.
import AppKit
import UniformTypeIdentifiers

@objc(CmuxShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
        let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, URL)] = []
        for (index, provider) in providers.enumerated() {
            guard let type = [UTType.fileURL, UTType.image].map(\.identifier)
                .first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
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
            guard !urls.isEmpty else {
                context.cancelRequest(withError: CocoaError(.fileReadNoSuchFile))
                return
            }
            // Contents/PlugIns/CmuxShare.appex -> the .app that carries it, never another copy.
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
                DispatchQueue.main.async {
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
