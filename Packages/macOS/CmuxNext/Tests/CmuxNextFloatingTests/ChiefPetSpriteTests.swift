import AppKit
import CmuxNextDesign
@testable import CmuxNextFloating
import Foundation
import Testing

/// The floating pet's animated characters (`cmux-avatar/1`): the row each Chief state draws, the
/// facing, and when the frames move. A still character (the nine) never gets a sprite.
@MainActor @Suite(.serialized) struct ChiefPetSpriteTests {
    static func defaults() -> UserDefaults {
        let name = "ChiefPetSpriteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func sheet(columns: Int, rows: Int) -> CGImage {
        let context = CGContext(data: nil, width: columns * 8, height: rows * 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    static func sprite(_ states: String, faces: String = "right", rows: Int = 8) -> ChiefPetSprite? {
        let json = #"{"format":"cmux-avatar/1","frame":{"width":8,"height":8},"fps":8,"faces":"\#(faces)","states":{\#(states)}}"#
        return ChiefPetSprite(sheet: sheet(columns: 8, rows: rows), json: Data(json.utf8))
    }

    @Test func onlyMochiIsAnimatedAndItHasEveryState() throws {
        for mascot in ChiefPetMascot.allCases where mascot != .mochi {
            #expect(mascot.sprite == nil, "\(mascot.rawValue) stays a still character")
        }
        let mochi = try #require(ChiefPetMascot.mochi.sprite)
        let rows = ChiefPetState.allCases.map { mochi.track($0, facingRight: true).row }
        #expect(rows == [0, 1, 2, 3, 4, 5])
        #expect(mochi.track(.done, facingRight: true).loop == false)
        #expect(mochi.track(.error, facingRight: true).loop == false)
        #expect(mochi.track(.working, facingRight: true).frames == 8)
        #expect(mochi.frame(row: 1, 7)?.width == 32)
    }

    @Test func missingStatesFallBackAndTheOtherFacingMirrors() throws {
        let sprite = try #require(Self.sprite(#""idle":{"row":0,"frames":2},"working":{"row":3,"frames":6,"rowLeft":6}"#))
        #expect(sprite.track(.thinking, facingRight: true).row == 3, "thinking borrows working's row")
        #expect(sprite.track(.waiting, facingRight: true).row == 0, "waiting borrows idle's row")
        #expect(sprite.track(.idle, facingRight: false).mirrored)
        #expect(!sprite.track(.idle, facingRight: true).mirrored)
        #expect(sprite.track(.working, facingRight: false) == .init(row: 6, frames: 6, fps: 8, loop: true, mirrored: false))
        let both = try #require(Self.sprite(#""idle":{"row":0,"frames":2,"rowRight":5,"rowLeft":6}"#))
        #expect(both.track(.idle, facingRight: true).row == 0, "the facing the frames are drawn in keeps its row")
        #expect(both.track(.idle, facingRight: false).row == 6)
        let left = try #require(Self.sprite(#""idle":{"row":0,"frames":2}"#, faces: "left"))
        #expect(left.track(.idle, facingRight: true).mirrored)
        #expect(Self.sprite(#""working":{"row":0,"frames":2}"#) == nil, "no idle row: not a sprite")
        // A row or frame count past the sheet is clamped to it.
        let small = try #require(Self.sprite(#""idle":{"row":12,"frames":20}"#, rows: 2))
        #expect(small.track(.idle, facingRight: true) == .init(row: 1, frames: 8, fps: 8, loop: true, mirrored: false))
    }

    @Test func framesMoveOnlyWhileShownActiveAndMotionAllowed() throws {
        // The frames step only when loops may run (`Motion.home.animatesLoops`): pin Reduce Motion off.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let defaults = Self.defaults()
        var active = true
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }),
                                            appIsActive: { active })
        defer { controller.sync(false) }
        var reduce = false
        controller.reduceMotion = { reduce }
        controller.setMascot(.mochi)
        controller.sync(true)
        controller.setState(.working)
        let panel = try #require(controller.panel)
        let layer = panel.pet.sprite
        #expect(!layer.layer.isHidden)
        #expect(layer.shown?.state == .working)
        #expect(layer.isMoving == controller.characterMoves)
        // cmux in the background: one frame, nothing runs.
        active = false
        controller.render(animated: false)
        #expect(!controller.characterMoves)
        #expect(!layer.isMoving)
        // Reduce Motion: still too.
        active = true
        reduce = true
        controller.drawCharacter()
        #expect(!layer.isMoving)
        // Turned off: hidden, nothing runs.
        reduce = false
        controller.sync(false)
        #expect(!controller.characterMoves)
        #expect(!layer.isMoving)
    }

    @Test func aFinishedTurnPlaysDoneThenAStillCharacterHasNoSprite() throws {
        let defaults = Self.defaults()
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }))
        defer { controller.sync(false) }
        controller.setMascot(.mochi)
        controller.sync(true)
        controller.setState(.working)
        controller.setState(.idle)
        #expect(controller.drawnState == .done, "a turn that ends plays done once")
        controller.setState(.waiting)
        #expect(controller.drawnState == .waiting, "a new state replaces done at once")
        controller.setState(.error)
        #expect(controller.panel?.pet.sprite.shown?.state == .error)
        // The nine still characters keep their picture and no sprite layer shows.
        controller.setMascot(.fox)
        #expect(controller.sprite == nil)
        #expect(controller.panel?.pet.sprite.layer.isHidden == true)
        controller.setState(.working)
        controller.setState(.idle)
        #expect(controller.drawnState == .idle, "a still character has no done row to play")
    }

    /// A layer's contents as the image it holds, if it is one.
    static func image(_ contents: Any?) -> CGImage? {
        guard let contents else { return nil }
        let object = contents as CFTypeRef
        guard CFGetTypeID(object) == CGImage.typeID else { return nil }
        return unsafeDowncast(object, to: CGImage.self)
    }

    /// The red channel of an image's top-left pixel.
    static func red(_ image: CGImage?) -> UInt8? {
        guard let image else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 1 - image.height, width: image.width, height: image.height))
        return pixel[0]
    }

    /// Still, a once-only row stands on its frame 0 (`cmux-avatar/1`), not on its last.
    @Test func aStillOnceOnlyRowStandsOnFrameZero() throws {
        // The frames step only when loops may run (`Motion.home.animatesLoops`): pin Reduce Motion off.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        // Each column of the sheet is its own shade of red: column c is 20 * (c + 1).
        let context = CGContext(data: nil, width: 64, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for column in 0..<8 {
            context.setFillColor(red: CGFloat(20 * (column + 1)) / 255, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: column * 8, y: 0, width: 8, height: 16))
        }
        let json = #"{"format":"cmux-avatar/1","frame":{"width":8,"height":8},"states":{"idle":{"row":0,"frames":8},"error":{"row":1,"frames":8,"loop":false}}}"#
        let sprite = try #require(ChiefPetSprite(sheet: context.makeImage()!, json: Data(json.utf8)))
        let drawn = ChiefPetSpriteLayer()
        drawn.show(sprite, state: .error, facingRight: true, moving: false)
        #expect(!drawn.isMoving)
        #expect((Self.red(Self.image(drawn.layer.contents)) ?? 255) < 40, "frame 0 (red 20), not the last frame")
        drawn.show(sprite, state: .error, facingRight: true, moving: true)
        #expect(drawn.isMoving)
        let steps = try #require(drawn.layer.animation(forKey: ChiefPetSpriteLayer.animationKey))
        #expect(steps.repeatCount == 0, "one pass")
        #expect((Self.red(Self.image(drawn.layer.contents)) ?? 0) > 140, "after its pass it holds the last frame (red 160)")
    }

    /// The person's upload covers an animated character; without it the character draws again.
    @Test func anUploadCoversTheAnimatedCharacter() throws {
        // The frames step only when loops may run (`Motion.home.animatesLoops`): pin Reduce Motion off.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ChiefPetSpriteTests-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let rep = NSBitmapImageRep(cgImage: Self.sheet(columns: 1, rows: 1))
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
        let clip = try #require(ChiefPetClip(file: file))
        let panel = ChiefPetPanel(defaults: Self.defaults())
        let mochi = try #require(ChiefPetMascot.mochi.sprite)
        panel.pet.animate(mochi, state: .working, facingRight: true, moving: true)
        #expect(panel.pet.sprite.isMoving)
        panel.pet.play(clip)
        #expect(panel.pet.sprite.layer.isHidden)
        #expect(!panel.pet.sprite.isMoving)
        panel.pet.animate(mochi, state: .working, facingRight: true, moving: true)
        #expect(panel.pet.sprite.layer.isHidden, "the upload stays on top")
        panel.pet.play(nil)
        panel.pet.animate(mochi, state: .working, facingRight: true, moving: true)
        #expect(!panel.pet.sprite.layer.isHidden)
        // An upload that fails to read (play(nil) again) never puts the still under the moving frames.
        panel.pet.play(nil)
        #expect(panel.pet.characterContents == nil)
    }

    /// Turned off mid-`done`, the pet comes back in the Chief's state, not stuck on done.
    @Test func turningOffEndsDone() {
        let defaults = Self.defaults()
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }))
        defer { controller.sync(false) }
        controller.setMascot(.mochi)
        controller.sync(true)
        controller.setState(.working)
        controller.setState(.idle)
        #expect(controller.drawnState == .done)
        controller.sync(false)
        controller.sync(true)
        #expect(controller.drawnState == .idle)
        #expect(controller.panel?.pet.sprite.shown?.state == .idle)
    }

    /// A pet summoned with the setting off still plays `done` when the turn ends: each state change
    /// syncs off again (`start`), which must not cut the summoned pet's `done` short.
    @Test func aSummonedPetPlaysDoneWithTheSettingOff() {
        let defaults = Self.defaults()
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }))
        defer { controller.closeReply(); controller.sync(false) }
        controller.setMascot(.mochi)
        controller.sync(false)
        controller.summon(petOn: false)
        controller.setState(.working)
        controller.sync(false)
        controller.setState(.idle)
        controller.sync(false)
        #expect(controller.drawnState == .done, "the summoned pet plays done once")
        #expect(controller.panel?.pet.sprite.shown?.state == .done)
        controller.closeReply()
        controller.sync(false)
        #expect(controller.drawnState == .idle, "gone with its box, a done cut short ends")
    }

    /// A screen change that leaves the pet where it is still tells the controller, which redraws the facing.
    @Test func aScreenChangeWithNoMoveStillRedraws() {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        panel.visibleFrame = { CGRect(x: 0, y: 0, width: 1000, height: 800) }
        panel.setFrameOrigin(CGPoint(x: 800, y: 20))
        var told = 0
        panel.onKeptOnScreen = { told += 1 }
        panel.keepOnScreen()
        #expect(told == 1)
    }

    /// The pet faces the side of its screen it sits on.
    @Test func facesTheSideItIsDockedToward() {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        panel.visibleFrame = { CGRect(x: 0, y: 0, width: 1000, height: 800) }
        panel.setFrameOrigin(CGPoint(x: 800, y: 20))
        #expect(panel.facesRight)
        panel.setFrameOrigin(CGPoint(x: 40, y: 20))
        #expect(!panel.facesRight)
    }
}
