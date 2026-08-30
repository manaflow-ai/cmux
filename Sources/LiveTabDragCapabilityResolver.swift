import AppKit
import Bonsplit

/// Memoizes transfer decoding for a pasteboard generation while consulting the
/// process-local registry for liveness on every hit.
///
/// Portal and pane hit testing runs for every pointer event. The pasteboard's
/// change count is stable throughout a drag, so the injected transfer resolver
/// runs once per generation. Registry validation remains the authority because
/// revocation does not always advance AppKit's change count. The registry owns
/// a bounded token/liveness cache, so this validation does not re-decode the
/// pasteboard payload on each pointer event.
@MainActor
final class LiveTabDragCapabilityResolver {
    typealias RegistryProvider = @MainActor () -> TabDragTransferRegistry?
    typealias TransferResolver = @MainActor (
        _ registry: TabDragTransferRegistry,
        _ pasteboard: NSPasteboard
    ) -> TabDragTransfer?

    /// The bounded memoized lookup key and value stay private to this resolver.
    private typealias Cache = (
        registryIdentity: ObjectIdentifier,
        pasteboardName: NSPasteboard.Name,
        pasteboardChangeCount: Int,
        transfer: TabDragTransfer?
    )

    private let registryProvider: RegistryProvider
    private let transferResolver: TransferResolver
    private var cache: Cache?

    deinit {}

    init(
        registryProvider: @escaping RegistryProvider,
        transferResolver: @escaping TransferResolver = { registry, pasteboard in
            registry.resolve(from: pasteboard)
        }
    ) {
        self.registryProvider = registryProvider
        self.transferResolver = transferResolver
    }

    /// Resolves a live transfer while keeping registry revocation authoritative.
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
            // Pasteboard generations are not the registry's liveness
            // generation. AppKit can leave the same change count in place when
            // a source ends (or when a replacement writes the same value), so
            // validate the cached result against the authoritative registry on
            // every cache hit. Registry resolution is generation-cached and
            // weak-lease-aware, keeping this check bounded without decoding
            // the payload per pointer event. A cache miss is also re-opened
            // when a new live registration appears without a pasteboard-
            // generation change.
            let liveTransfer = registry.resolve(from: pasteboard)
            guard let liveTransfer else {
                self.cache = Cache(
                    registryIdentity: registryIdentity,
                    pasteboardName: pasteboardName,
                    pasteboardChangeCount: changeCount,
                    transfer: nil
                )
                return nil
            }
            if cache.transfer == liveTransfer {
                return cache.transfer
            }
            let transfer = transferResolver(registry, pasteboard)
            self.cache = Cache(
                registryIdentity: registryIdentity,
                pasteboardName: pasteboardName,
                pasteboardChangeCount: changeCount,
                transfer: transfer
            )
            return transfer
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
