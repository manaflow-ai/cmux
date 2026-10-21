import Foundation

/// The manifest facts of the listed extensions (``ExtensionManifestFacts``), read off the main
/// thread once per extension folder. The toolbar prepares the bubble ahead of a click, so the
/// facts are usually in before the bubble opens; a load that finishes later calls ``onLoad`` and
/// the bubble re-renders its rows in place.
@MainActor
final class ExtensionManifestCache {
    private var facts: [String: ExtensionManifestFacts] = [:]
    /// Folders read, with or without a manifest, and folders being read.
    private var requested: Set<String> = []
    /// Runs when a load brought new facts.
    var onLoad: (() -> Void)?

    /// The facts of `info`, nil until its manifest is read (or when it has none).
    func facts(for info: BrowserExtensionInfo) -> ExtensionManifestFacts? { facts[info.path] }

    /// Starts reading the manifests of `infos` not read yet.
    func load(_ infos: [BrowserExtensionInfo]) {
        let paths = infos.map(\.path).filter { !$0.isEmpty && !requested.contains($0) }
        guard !paths.isEmpty else { return }
        requested.formUnion(paths)
        Task.detached(priority: .userInitiated) { [weak self] in
            let read = paths.compactMap { path in ExtensionManifestFacts(folder: path).map { (path, $0) } }
            await self?.store(read)
        }
    }

    private func store(_ read: [(String, ExtensionManifestFacts)]) {
        guard !read.isEmpty else { return }
        for (path, value) in read { facts[path] = value }
        onLoad?()
    }

    /// Sets `info`'s facts directly (tests).
    func set(_ value: ExtensionManifestFacts, for info: BrowserExtensionInfo) {
        requested.insert(info.path)
        facts[info.path] = value
    }
}
