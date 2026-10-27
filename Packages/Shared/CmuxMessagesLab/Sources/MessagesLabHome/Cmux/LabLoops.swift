import CmuxHomeCore
import Foundation
import QuartzCore

/// cmux (p14-energy-115): where the vendored transcript's infinite loops run (the caret's blink, the
/// typing dots, the typing bubble's breath and clip): the host's ``LoopHost``, so none runs while its
/// window is hidden or occluded. The cells and the window view call it; they run on the main thread
/// (UIKit's rule) but are not main-actor, as their shim `UIView` is not yet (README), so this is
/// their seam to the main-actor host.
final class LabLoops {
    private let host: any LoopHost

    /// - Parameter host: The host's loops (CmuxNext: `HomeLoopProbe`).
    init(_ host: any LoopHost) {
        self.host = host
    }

    /// A view no host gave one (a cell or a field made alone in a test, the harness): each loop runs
    /// as attached.
    static func standalone() -> LabLoops { LabLoops(StandaloneLoopHost()) }

    /// Runs `make`'s loop on `layer` under `key` whenever the host is visible (``LoopHost/attach(_:key:make:)``).
    func attach(_ layer: CALayer, key: String, make: @escaping @MainActor () -> CAAnimation?) {
        guard Thread.isMainThread else { return assertionFailure("LabLoops.attach(\(key)) off the main thread") }
        MainActor.assumeIsolated { host.attach(layer, key: key, make: make) }  // main-proof: guarded by Thread.isMainThread above
    }

    /// Takes the loop under `key` off `layer` for good (``LoopHost/detach(_:key:)``).
    func detach(_ layer: CALayer, key: String) {
        guard Thread.isMainThread else { return assertionFailure("LabLoops.detach(\(key)) off the main thread") }
        MainActor.assumeIsolated { host.detach(layer, key: key) }  // main-proof: guarded by Thread.isMainThread above
    }
}
