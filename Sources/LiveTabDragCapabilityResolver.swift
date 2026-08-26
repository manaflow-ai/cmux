import AppKit
import Bonsplit

/// Caches one pasteboard-generation lookup for the process-local tab-drag registry.
///
/// Portal and pane hit testing runs for every pointer event. The pasteboard's
/// change count is stable throughout a drag, so decoding the opaque JSON
/// capability once per pasteboard generation keeps those hot paths bounded while
/// retaining the registry as the liveness authority.
@MainActor
final class LiveTabDragCapabilityResolver {
    typealias RegistryProvider = @MainActor () -> TabDragTransferRegistry?
    typealias TransferResolver = @MainActor (
        _ registry: TabDragTransferRegistry,
        _ pasteboard: NSPasteboard
    ) -> TabDragTransfer?

    private struct Cache {
        let registryIdentity: ObjectIdentifier
        let pasteboardName: NSPasteboard.Name
        let pasteboardChangeCount: Int
        let transfer: TabDragTransfer?
    }

    private let registryProvider: RegistryProvider
    private let transferResolver: TransferResolver
    private var cache: Cache?

    init(
        registryProvider: @escaping RegistryProvider,
        transferResolver: @escaping TransferResolver = { registry, pasteboard in
            registry.resolve(from: pasteboard)
        }
    ) {
        self.registryProvider = registryProvider
        self.transferResolver = transferResolver
    }

    /// Resolves a live transfer, decoding at most once per registry/pasteboard generation.
    func resolve(from pasteboard: NSPasteboard) -> TabDragTransfer? {
        guard let registry = registryProvider() else {
            cache = nil
            return nil
        }
        let registryIdentity = ObjectIdentifier(registry)
        let pasteboardName = pasteboard.name
        let changeCount = pasteboard.changeCount
        if let cache,
           cache.registryIdentity == registryIdentity,
           cache.pasteboardName == pasteboardName,
           cache.pasteboardChangeCount == changeCount {
            return cache.transfer
        }

        let transfer = transferResolver(registry, pasteboard)
        cache = Cache(
            registryIdentity: registryIdentity,
            pasteboardName: pasteboardName,
            pasteboardChangeCount: changeCount,
            transfer: transfer
        )
        return transfer
    }

    /// Drops the cached generation after a host-owned capability mutation.
    func invalidate() {
        cache = nil
    }
}
