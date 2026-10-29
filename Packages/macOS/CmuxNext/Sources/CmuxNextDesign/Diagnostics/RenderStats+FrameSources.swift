public import AppKit
import AVFoundation
import QuartzCore

/// Frame sources no `FrameScheduler` sees, so the wakeup ledger cannot name them:
/// infinite Core Animation loops (NightSky's twinkle, Motion's spinners) and
/// playing video layers (BackdropVideoView's `AVPlayerLooper`). `debug.layers`
/// with `frame_sources: true` reports both at each end of an idle window
/// (scripts/cmux-next/idle-budget.py's power sessions).
///
/// Chrome's model: the compositor keeps asking for begin-frames while
/// `cc::AnimationHost::NeedsTickAnimations()` (cc/animation/animation_host.cc)
/// says an animation runs, so an idle page with one is never idle. Here the
/// render server ticks these loops, so a layer walk is the only way to name them.
extension RenderStats {
    /// Infinite-repeat Core Animation animations on every layer of `windows`,
    /// shown or not, per owner (the nearest view at or above the layer).
    public static func loopingAnimations(in windows: [NSWindow]) -> [String: Int] {
        loopingAnimations(under: rootLayers(of: windows))
    }

    /// `AVPlayerLayer`s of `windows` whose player is playing (rate not 0), per
    /// owner (the nearest view at or above the layer): each decodes and
    /// composites every video frame.
    public static func playingVideoLayers(in windows: [NSWindow]) -> [String: Int] {
        playingVideoLayers(under: rootLayers(of: windows))
    }

    static func loopingAnimations(under roots: [CALayer]) -> [String: Int] {
        var counts: [String: Int] = [:]
        forEachLayer(under: roots) { layer in
            let loops = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }.filter(\.loopsForever).count
            if loops > 0 { counts[owningViewName(of: layer), default: 0] += loops }
        }
        return counts
    }

    static func playingVideoLayers(under roots: [CALayer]) -> [String: Int] {
        var counts: [String: Int] = [:]
        forEachLayer(under: roots) { layer in
            guard let player = (layer as? AVPlayerLayer)?.player, player.rate != 0 else { return }
            counts[owningViewName(of: layer), default: 0] += 1
        }
        return counts
    }

    private static func rootLayers(of windows: [NSWindow]) -> [CALayer] {
        windows.compactMap { ($0.contentView?.superview ?? $0.contentView)?.layer }
    }

    private static func forEachLayer(under roots: [CALayer], _ body: (CALayer) -> Void) {
        var pending = roots
        while let layer = pending.popLast() {
            body(layer)
            pending += layer.sublayers ?? []
        }
    }

    /// The class of the nearest view whose layer is `layer` or an ancestor of
    /// it, else the layer's own class.
    private static func owningViewName(of layer: CALayer) -> String {
        var current: CALayer? = layer
        while let candidate = current {
            if let view = candidate.delegate as? NSView { return name(of: Swift.type(of: view)) }
            current = candidate.superlayer
        }
        return name(of: Swift.type(of: layer))
    }
}
