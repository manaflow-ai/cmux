public import AppKit
public import SwiftUI

/// Detector for a connection state that moves content (Leo, 2026-11-21: "these messages should not be pushing up
/// the text ... stop layout shifting"). A surface marks the content a link state must never move with
/// ``SwiftUI/View/layoutProbe(_:into:)``; ``LayoutShiftProbe/measure(size:_:)`` lays one state of the surface out
/// in a window and returns those frames, and ``LayoutShiftProbe/shift(_:from:)`` the most any of them moved, in
/// points, from the connected frames. 0 is the rule: a banner above a list, a row in a stack or a spinner in place
/// of the content fails with its points.
@MainActor
public final class LayoutFrames {
    public var frames: [String: CGRect] = [:]
    public init() {}
}

private struct LayoutProbe: ViewModifier {
    let id: String
    let frames: LayoutFrames

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { frames.frames[id] = frame }
                    .onChange(of: frame) { _, moved in frames.frames[id] = moved }
            }
        }
    }
}

extension View {
    /// Reports this view's frame, by `id`, into `frames` as it lays out.
    public func layoutProbe(_ id: String, into frames: LayoutFrames) -> some View {
        modifier(LayoutProbe(id: id, frames: frames))
    }
}

@MainActor
public enum LayoutShiftProbe {
    /// Lays `content` out in a borderless window of `size` for a few display frames (an enter transition included)
    /// and returns the frames its probes reported. `content` gets the probes' recorder.
    public static func measure(size: CGSize = CGSize(width: 480, height: 360),
                               _ content: (LayoutFrames) -> some View) async -> [String: CGRect] {
        let frames = LayoutFrames()
        let host = NSHostingView(rootView: content(frames).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer {
            window.contentView = nil
            window.closeAfterTest()
        }
        window.contentView = host
        for _ in 0 ..< 12 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(16)) // test: one display frame of layout
        }
        host.layoutSubtreeIfNeeded()
        return frames.frames
    }

    /// The most any probe moved or resized from `base`, in points; a probe that vanished counts as its height.
    public static func shift(_ frames: [String: CGRect], from base: [String: CGRect]) -> CGFloat {
        base.reduce(0) { worst, entry in
            guard let moved = frames[entry.key] else { return max(worst, entry.value.height) }
            return max(worst, abs(moved.minX - entry.value.minX), abs(moved.minY - entry.value.minY),
                       abs(moved.width - entry.value.width), abs(moved.height - entry.value.height))
        }
    }
}
