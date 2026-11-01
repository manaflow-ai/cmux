import Foundation

/// Write, rename and delete events of one folder (the macOS wallpaper store), delivered on the
/// main actor, until released: its `deinit` cancels the source, which closes the descriptor.
///
/// The source watches the folder it opened. When the folder itself is renamed or deleted (macOS
/// replaced the store), `handler` hears `replaced` and the owner makes a new source for the path.
nonisolated final class WallpaperStoreSource {
    private let source: any DispatchSourceFileSystemObject

    /// Starts watching `folder`; nil when it can't be opened (no store yet).
    /// - Parameters:
    ///   - folder: The folder to watch.
    ///   - handler: Main-actor work per event; `replaced` when the folder itself moved or went away.
    init?(_ folder: URL, handler: @escaping @MainActor (_ replaced: Bool) -> Void) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak source] in
            let replaced = source.map { !$0.data.isDisjoint(with: [.rename, .delete]) } ?? false
            Task { @MainActor in handler(replaced) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
