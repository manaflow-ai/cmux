internal import QuartzCore

/// Immutable ownership passed to the dedicated Metal executor.
///
/// `CAMetalLayer.nextDrawable()` is designed for render-thread use. AppKit
/// installs and replaces the layer on the main actor; the executor only asks
/// for drawables and never mutates view hierarchy or layer configuration.
final class TerminalRenderMetalLayerHandle: @unchecked Sendable {
    let layer: CAMetalLayer

    init(_ layer: CAMetalLayer) {
        self.layer = layer
    }
}
