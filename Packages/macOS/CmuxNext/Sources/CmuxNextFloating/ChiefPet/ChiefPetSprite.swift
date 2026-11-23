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

/// A screen direction an animated character looks or leans toward (`cmux-avatar/1` `directions`).
public nonisolated enum ChiefPetDirection: String, CaseIterable, Sendable {
    case left, right, up, down

    var opposite: ChiefPetDirection {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }

    var isHorizontal: Bool { self == .left || self == .right }

    /// The dominant way a move of `dx`, `dy` screen points goes (y up, as AppKit's screen points), or
    /// nil when it is shorter than `minimum` on both axes. A tie goes to the side (left or right).
    static func dominant(dx: CGFloat, dy: CGFloat, minimum: CGFloat = 2) -> ChiefPetDirection? {
        guard max(abs(dx), abs(dy)) >= minimum else { return nil }
        if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
        return dy > 0 ? .up : .down
    }
}

/// What a direction row draws: the character looking that way (thinking), or leaning toward a drag.
public nonisolated enum ChiefPetLean: String, CaseIterable, Sendable {
    case look, drag
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
        /// Rows toward a screen direction (`look`, `drag`), absent in older manifests.
        var directions: [String: [String: State]]?
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

    /// The row `motion` draws toward the screen direction `direction`, facing right or left, or nil when
    /// the manifest has none (the caller draws the state). Rows are drawn facing `faces`: turned, the
    /// mirrored direction's row draws mirrored, and up and down mirror with the facing; a missing left or
    /// right borrows the other side's row, mirrored (webviews `directionTrack`).
    func track(_ motion: ChiefPetLean, toward direction: ChiefPetDirection, facingRight right: Bool) -> Track? {
        guard let specs = manifest.directions?[motion.rawValue] else { return nil }
        let turned = right != (manifest.faces != "left")
        let drawn = turned && direction.isHorizontal ? direction.opposite : direction
        var mirrored = turned
        var spec = specs[drawn.rawValue]
        if spec == nil, direction.isHorizontal {
            spec = specs[drawn.opposite.rawValue]
            mirrored.toggle()
        }
        guard let spec else { return nil }
        let rows = Int(CGFloat(sheet.height) / frameSize.height)
        let columns = Int(CGFloat(sheet.width) / frameSize.width)
        // A row past the sheet (an older bundled sheet with a newer manifest) has no frames: no row.
        guard spec.row < rows else { return nil }
        return Track(row: spec.row, frames: max(1, min(spec.frames, columns)),
                     fps: min(max(spec.fps ?? manifest.fps ?? 8, 1), 30), loop: spec.loop ?? true, mirrored: mirrored)
    }

    /// Whether the character has look rows (thinking looks around) or drag rows (it leans when dragged).
    func has(_ motion: ChiefPetLean) -> Bool { manifest.directions?[motion.rawValue]?.isEmpty == false }

    /// The order thinking looks around in, one look after every two passes of the thinking row.
    static let lookTour: [ChiefPetDirection] = [.left, .right, .up, .down]

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
///
/// Thinking, a character with look rows looks around: one keyframe animation walks the thinking row
/// twice, then a look (left, right, up, down in turn), and loops, so a look comes every 2 to 3 s with no
/// timer and no layout. While a drag holds the pet (`drag(_:)`), it draws the drag row for the way it
/// is pulled, and its state again on the drop.
@MainActor
final class ChiefPetSpriteLayer {
    static let animationKey = "chiefPet.frames"
    /// Thinking passes between two looks.
    static let passesPerLook = 2
    let layer = CALayer()
    private(set) var shown: (state: ChiefPetState, right: Bool, moving: Bool)?
    /// What the layer draws now: the state's row, thinking looking around, or a drag's lean.
    enum Pose: Equatable { case state, lookTour, drag(ChiefPetDirection) }
    private(set) var pose: Pose = .state
    /// The last `show` call's sprite, so a drag's end draws the state again.
    private var sprite: ChiefPetSprite?
    /// The way a drag pulls the pet now; nil when no drag holds it.
    private(set) var dragging: ChiefPetDirection?

    init() {
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contentsGravity = .resizeAspect
        layer.isHidden = true
    }

    /// Whether a row is stepping now.
    var isMoving: Bool { layer.animation(forKey: Self.animationKey) != nil }

    /// Draws `sprite`'s `state` facing right or left; `moving` steps its row, else its first frame
    /// stands. A nil sprite (a still character) hides the layer. While a drag holds the pet, its lean
    /// stays drawn and this state shows on the drop.
    func show(_ sprite: ChiefPetSprite?, state: ChiefPetState, facingRight right: Bool, moving: Bool) {
        self.sprite = sprite
        guard let sprite else {
            layer.removeAnimation(forKey: Self.animationKey)
            layer.isHidden = true
            shown = nil
            pose = .state
            return
        }
        let track = sprite.track(state, facingRight: right)
        let animate = moving && track.frames > 1
        // A lean holds only while things may move: Reduce Motion turning on mid-drag (the controller redraws) drops it.
        let wanted: Pose = if let dragging, Motion.home.animatesMovement, sprite.track(.drag, toward: dragging, facingRight: right) != nil {
            .drag(dragging)
        } else if animate, state == .thinking || state == .working, sprite.has(.look) { // a chat at work is thinking
            .lookTour
        } else {
            .state
        }
        // The same state, facing, motion and pose keeps running where it is: no restart on each redraw.
        if let shown, shown == (state, right, animate), pose == wanted, !layer.isHidden { return }
        shown = (state, right, animate)
        pose = wanted
        switch wanted {
        case .state: draw(sprite, track, animate: animate)
        case .drag(let direction):
            // A lean is drawn even when the frames may not step (cmux in the back): its first frame stands.
            if let lean = sprite.track(.drag, toward: direction, facingRight: right) { draw(sprite, lean, animate: animate && lean.frames > 1) }
        case .lookTour: tour(sprite, track, facingRight: right)
        }
    }

    /// A drag pulls the pet toward `direction` (nil: the drag ended). The lean shows only where the home
    /// gate lets things move (`Motion.home.animatesMovement`: Reduce Motion, calm mode and the switches
    /// turn it off); the drop draws the state again.
    func drag(_ direction: ChiefPetDirection?) {
        let next = Motion.home.animatesMovement ? direction : nil
        guard next != dragging else { return }
        dragging = next
        guard let shown else { return }
        // Redraw the remembered state: `show` picks the lean while a drag holds the pet.
        self.shown = nil
        show(sprite, state: shown.state, facingRight: shown.right, moving: shown.moving)
    }

    private func draw(_ sprite: ChiefPetSprite, _ track: ChiefPetSprite.Track, animate: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.isHidden = false
        layer.setAffineTransform(track.mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        // Still, every row stands on its frame 0 (`cmux-avatar/1`); only a once-only row that played
        // to its end holds its last frame (below).
        layer.contents = sprite.frame(row: track.row, 0)
        CATransaction.commit()
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

    /// Thinking that looks around: the thinking row `passesPerLook` times, then one pass of a look row,
    /// for each look in `lookTour`, as one looping keyframe animation (the same gate and stop as a row).
    /// A look whose row would flip the facing (a borrowed side) is left out.
    private func tour(_ sprite: ChiefPetSprite, _ thinking: ChiefPetSprite.Track, facingRight right: Bool) {
        let looks = ChiefPetSprite.lookTour.compactMap { sprite.track(.look, toward: $0, facingRight: right) }
            .filter { $0.mirrored == thinking.mirrored }
        guard !looks.isEmpty else { return draw(sprite, thinking, animate: true) }
        let pass = (0..<thinking.frames).compactMap { sprite.frame(row: thinking.row, $0) }
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        for look in looks {
            for _ in 0..<Self.passesPerLook {
                frames += pass
                delays += pass.map { _ in 1 / thinking.fps }
            }
            let row = (0..<look.frames).compactMap { sprite.frame(row: look.row, $0) }
            frames += row
            delays += row.map { _ in 1 / look.fps }
        }
        draw(sprite, thinking, animate: false)
        // Nil when loops are off: thinking's first frame stands.
        guard let steps = Motion.home.clipAnimation(frames, delays: delays) else { return }
        layer.add(steps, forKey: Self.animationKey)
    }
}
