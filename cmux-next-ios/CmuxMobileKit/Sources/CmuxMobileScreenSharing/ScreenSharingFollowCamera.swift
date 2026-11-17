#if os(iOS)
import CmuxMobileLinkFFI
public import CmuxScreenKit
public import Foundation
import Observation
public import QuartzCore
public import UIKit

/// Follow mode for one shared screen: the viewer's ``ScreenCamera`` over the
/// shared follow camera (Rust, `FollowCamera`). The Mac's `focus` channel
/// feeds it (pointer, text caret, focused window, changed pixels); the
/// screen view asks it for the crop once per display frame.
///
/// The crop starts half the display's width at the display's full height:
/// on a portrait iPhone about twice the fit-to-width zoom, wide enough for a
/// terminal line, shown letterboxed. A pinch sets the width the next crop
/// starts from. Reduce Motion cuts instead of panning.
@MainActor @Observable
public final class ScreenSharingFollowCamera: ScreenCamera {
    public private(set) var isAvailable = false
    public private(set) var isFollowing = false
    public private(set) var isHeld = false

    /// The share of the display's width a new crop starts at.
    @ObservationIgnored private(set) var widthShare = 0.5
    @ObservationIgnored private var engine: FollowCamera?
    @ObservationIgnored private var engineShape: Shape?
    /// The Mac's display in its own pixels, from its `source` event.
    @ObservationIgnored private var source: CGSize?
    /// The last `source` and `window` events: a new engine (a rotation, a
    /// new display size) starts from them.
    @ObservationIgnored private var replay: [String: String] = [:]
    @ObservationIgnored private let reduceMotion: () -> Bool
    @ObservationIgnored private let now: () -> CFTimeInterval

    /// What a new engine is made for.
    private struct Shape: Equatable {
        var aspect: Double
        var source: CGSize
        var reduceMotion: Bool
    }

    public init(reduceMotion: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled },
                now: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.reduceMotion = reduceMotion
        self.now = now
    }

    /// Makes this the session's camera and its `focus` channel's reader.
    public func attach(to session: ScreenSession) {
        session.camera = self
        session.onFocus = { [weak self] message in self?.receive(message) }
    }

    /// One `focus` channel message from the Mac.
    func receive(_ message: Data) {
        guard let line = String(data: message, encoding: .utf8),
              let head = try? JSONDecoder().decode(Head.self, from: message) else { return }
        switch head.kind {
        case "source":
            guard let w = head.w, let h = head.h, w > 0, h > 0 else { return }
            replay["source"] = line
            source = CGSize(width: w, height: h)
            isAvailable = true
        case "window":
            replay["window"] = line
        default:
            break
        }
        try? engine?.pushJson(line: line, nowUs: Self.micros(now()))
    }

    private struct Head: Decodable {
        var kind: String
        var w: Double?
        var h: Double?
    }

    // MARK: ScreenCamera

    public func crop(at time: CFTimeInterval, aspect: CGFloat) -> CGRect? {
        guard isFollowing, !isHeld, let source, aspect > 0 else { return nil }
        let engine = engine(for: Shape(aspect: (Double(aspect) * 100).rounded() / 100, source: source,
                                       reduceMotion: reduceMotion()))
        let rect = engine.advance(nowUs: Self.micros(time))
        return CGRect(x: rect.x / source.width, y: rect.y / source.height,
                      width: rect.w / source.width, height: rect.h / source.height)
    }

    public func personMoved(_ visible: CGRect) {
        guard isFollowing, let source, visible.width > 0, visible.height > 0 else { return }
        isHeld = true
        widthShare = min(max(Double(visible.width), 0.05), 1)
        engine?.manual(rect: FollowRect(x: visible.minX * source.width, y: visible.minY * source.height,
                                        w: visible.width * source.width, h: visible.height * source.height))
    }

    public func personTapped() -> Bool {
        guard isFollowing, isHeld else { return false }
        isHeld = false
        engine?.resume()
        return true
    }

    public func toggle() {
        if !isFollowing {
            isFollowing = true
            isHeld = false
            engine?.resume()
        } else if isHeld {
            _ = personTapped()
        } else {
            isFollowing = false
        }
    }

    // MARK: Engine

    /// The engine for this view shape, made again when the shape changes
    /// (a rotation, a new display size, Reduce Motion), from the last
    /// `source` and `window` events.
    private func engine(for shape: Shape) -> FollowCamera {
        if let engine, engineShape == shape { return engine }
        let (aspect, zoom) = Self.crop(widthShare: widthShare, viewAspect: shape.aspect, source: shape.source)
        let made = FollowCamera(aspect: aspect, zoom: zoom, sourceW: shape.source.width, sourceH: shape.source.height,
                                reduceMotion: shape.reduceMotion)
        let time = Self.micros(now())
        for kind in ["source", "window"] {
            if let line = replay[kind] { try? made.pushJson(line: line, nowUs: time) }
        }
        engine = made
        engineShape = shape
        return made
    }

    /// The engine's crop shape for a crop `widthShare` of the display wide in
    /// a view of `viewAspect`: the view's shape when it fits in the display's
    /// height, else full height (shown letterboxed). `zoom` divides the
    /// largest rect of that shape down to the width.
    nonisolated static func crop(widthShare: Double, viewAspect: Double, source: CGSize) -> (aspect: Double, zoom: Double) {
        let width = min(max(widthShare, 0.01), 1) * source.width
        let height = min(source.height, width / viewAspect)
        let aspect = width / height
        let largest = source.width / source.height > aspect ? source.height * aspect : source.width
        return (aspect, max(largest / width, 1))
    }

    nonisolated static func micros(_ time: CFTimeInterval) -> UInt64 {
        UInt64(max(time, 0) * 1_000_000)
    }
}
#endif
