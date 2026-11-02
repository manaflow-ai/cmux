public import AppKit
import CmuxNextDesign
import ImageIO
import QuartzCore

/// What the Chief is doing, as the pet draws it: one row of an animated character's sheet each.
public nonisolated enum ChiefPetState: String, CaseIterable, Sendable {
    case idle, working, thinking, waiting, done, error

    /// Where a state with no row of its own borrows one (`cmux-avatar/1`).
    var fallback: ChiefPetState? {
        switch self {
        case .idle: nil
        case .thinking: .working
        case .working, .waiting, .done, .error: .idle
        }
    }
}

/// An animated character (`cmux-avatar/1`, webviews `avatars/format.ts`): a sprite sheet with one row
/// per state and its `avatar.json`, bundled as `ChiefMascot<Name>Sheet.png` and `ChiefMascot<Name>.json`.
/// The nine still characters have none, and draw as before.
nonisolated struct ChiefPetSprite: Equatable {
    struct Track: Equatable {
        var row: Int
        var frames: Int
        var fps: Double
        var loop: Bool
        var mirrored: Bool

        /// How long one pass of the row takes.
        var duration: Double { Double(frames) / fps }
    }

    private struct Manifest: Decodable {
        struct Frame: Decodable { var width: Int; var height: Int }
        struct State: Decodable { var row: Int; var frames: Int; var fps: Double?; var loop: Bool?; var rowLeft: Int?; var rowRight: Int? }
        var format: String
        var frame: Frame
        var fps: Double?
        var faces: String?
        var states: [String: State]
    }

    let sheet: CGImage
    let frameSize: CGSize
    private let manifest: Manifest
    /// The idle row, which every state falls back to last (the manifest must have one).
    private let idle: Manifest.State

    static func == (a: Self, b: Self) -> Bool { a.sheet === b.sheet }

    /// The sheet and manifest, or nil when either is missing or does not read as `cmux-avatar/1`.
    init?(sheet: CGImage, json: Data) {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: json), manifest.format == "cmux-avatar/1",
              manifest.frame.width > 0, manifest.frame.height > 0, let idle = manifest.states["idle"] else { return nil }
        self.sheet = sheet
        self.manifest = manifest
        self.idle = idle
        frameSize = CGSize(width: manifest.frame.width, height: manifest.frame.height)
    }

    /// The bundled animated character `resource` (`ChiefPetMascot.resource`), if it has a sheet.
    static func bundled(_ resource: String) -> ChiefPetSprite? {
        guard let url = Bundle.module.url(forResource: resource + "Sheet", withExtension: "png"),
              let json = Bundle.module.url(forResource: resource, withExtension: "json").flatMap({ try? Data(contentsOf: $0) }),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return ChiefPetSprite(sheet: sheet, json: json)
    }

    /// The row `state` draws facing right (`right`) or left: a missing state borrows its fallback's,
    /// and the facing the frames are not drawn in uses its own row when given, else this one mirrored.
    func track(_ state: ChiefPetState, facingRight right: Bool) -> Track {
        var name = state
        while manifest.states[name.rawValue] == nil, let next = name.fallback { name = next }
        let spec = manifest.states[name.rawValue] ?? idle
        // A facing's own row is only for the facing the frames are not drawn in; theirs is `row`.
        let turned = right != (manifest.faces != "left")
        let own = turned ? (right ? spec.rowRight : spec.rowLeft) : nil
        let rows = Int(CGFloat(sheet.height) / frameSize.height)
        let columns = Int(CGFloat(sheet.width) / frameSize.width)
        return Track(row: min(own ?? spec.row, max(rows - 1, 0)), frames: max(1, min(spec.frames, columns)),
                     fps: min(max(spec.fps ?? manifest.fps ?? 8, 1), 30), loop: spec.loop ?? true,
                     mirrored: turned && own == nil)
    }

    /// Frame `index` of `row`, cut from the sheet (`CGImage.cropping` counts from the top left).
    func frame(row: Int, _ index: Int) -> CGImage? {
        sheet.cropping(to: CGRect(x: CGFloat(index) * frameSize.width, y: CGFloat(row) * frameSize.height,
                                  width: frameSize.width, height: frameSize.height))
    }
}

/// Draws a `ChiefPetSprite` on a layer: one frame, or the row stepping by a Core Animation keyframe
/// animation of its cut frames. No timer runs here; the render server steps the frames. `still` removes the animation
/// (the stop condition: Reduce Motion, the pet hidden, cmux in the background), and so does a new
/// state or facing before it adds its own.
@MainActor
final class ChiefPetSpriteLayer {
    static let animationKey = "chiefPet.frames"
    let layer = CALayer()
    private(set) var shown: (state: ChiefPetState, right: Bool, moving: Bool)?

    init() {
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contentsGravity = .resizeAspect
        layer.isHidden = true
    }

    /// Whether a row is stepping now.
    var isMoving: Bool { layer.animation(forKey: Self.animationKey) != nil }

    /// Draws `sprite`'s `state` facing right or left; `moving` steps its row, else its first frame
    /// stands. A nil sprite (a still character) hides the layer.
    func show(_ sprite: ChiefPetSprite?, state: ChiefPetState, facingRight right: Bool, moving: Bool) {
        guard let sprite else {
            layer.removeAnimation(forKey: Self.animationKey)
            layer.isHidden = true
            shown = nil
            return
        }
        let track = sprite.track(state, facingRight: right)
        let animate = moving && track.frames > 1
        // The same state, facing and motion keeps running where it is: no restart on each redraw.
        if let shown, shown == (state, right, animate), !layer.isHidden { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.isHidden = false
        layer.setAffineTransform(track.mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        // Still, every row stands on its frame 0 (`cmux-avatar/1`); only a once-only row that played
        // to its end holds its last frame (below).
        layer.contents = sprite.frame(row: track.row, 0)
        CATransaction.commit()
        shown = (state, right, animate)
        guard animate else { return }
        let frames = (0..<track.frames).compactMap { sprite.frame(row: track.row, $0) }
        // The motion layer's contents stepper (discrete, the render server's; nil when loops are off,
        // and then frame 0 stands).
        guard let steps = Motion.home.clipAnimation(frames, delays: frames.map { _ in 1 / track.fps }) else { return }
        if !track.loop {
            // One pass (0 is one in CAMediaTiming), then it holds its last frame.
            steps.repeatCount = 0
            steps.fillMode = .forwards
            layer.contents = frames.last
        }
        layer.add(steps, forKey: Self.animationKey)
    }
}
