import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Metal
import Testing

/// Living wallpapers (ask-722b8b001e): shaders that draw the window's backdrop every frame and
/// answer the pointer, listed in the picker beside the static and moving wallpapers.
@MainActor @Suite(.serialized, .closesItsWindows) struct ShaderWallpaperTests {
    @Test func everyShaderIsAPickerChoiceTheSettingReadsBack() {
        let ids = BackdropCatalog.shaders.map(\.id)
        #expect(ids == ["shader:currents", "shader:ripples", "shader:aurora", "shader:field", "shader:aero",
                        "shader:sakura", "shader:sumi", "shader:koi", "shader:snowfall", "shader:lanterns", "shader:rain",
                        "shader:matrix"])
        for choice in BackdropCatalog.shaders {
            #expect(BackdropSelection(id: choice.id) == choice, "\(choice.id) does not read back")
            #expect(choice.pickerCollection?.id == BackdropShader.collection)
            #expect(choice.shader != nil && !choice.isVideo)
            #expect(choice.followsAppearance, "\(choice.id) draws one still for light and dark")
            #expect(choice.imageURL(for: .light) != choice.imageURL(for: .dark))
            #expect(choice.title.isEmpty == false && choice.attribution.isEmpty == false)
        }
        #expect(BackdropSelection(id: "shader:plasma") == nil, "an unknown shader is not a setting value")
        let catalog = BackdropCatalog(systemDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), fileManager: .default)
        #expect(Array(catalog.choices.suffix(BackdropShader.allCases.count)) == BackdropCatalog.shaders,
                "the living wallpapers are not last in the picker")
    }

    @Test func aPosterFileNamesItsShaderAndAppearance() throws {
        for shader in BackdropShader.allCases {
            for dark in [false, true] {
                let poster = try #require(BackdropShader.poster(at: shader.posterURL(dark: dark)))
                #expect(poster.shader == shader && poster.dark == dark)
            }
        }
        #expect(BackdropShader.poster(at: URL(fileURLWithPath: "/tmp/currents-dark-v1.png")) == nil,
                "a file outside the posters folder is taken for a poster")
    }

    @Test func theUniformsMatchTheShaderLayout() {
        // float2, float2, 4 floats, float4[4] at 32, then float2, float2 at 96: 112 bytes in Metal.
        #expect(MemoryLayout<BackdropShaderUniforms>.stride == 112)
        #expect(MemoryLayout<BackdropShaderUniforms>.offset(of: \.rings) == 32)
        #expect(MemoryLayout<BackdropShaderUniforms>.offset(of: \.pointer) == 96)
    }

    /// Slow dark gradients band in an 8-bit drawable; every shader's last step is the 1-step
    /// triangular dither (reading note motion-backgrounds-color, "Banding and dithering").
    @Test func everyShaderEndsInTheDither() {
        let source = BackdropShaderSource.source
        for shader in BackdropShader.allCases {
            let start = source.range(of: "fragment float4 \(shader.fragmentName)(")
            #expect(start != nil, "\(shader) has no fragment")
            guard let start else { continue }
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    fragment ")?.lowerBound ?? rest.endIndex
            let returns = rest[..<end].components(separatedBy: "return float4(").dropFirst()
            #expect(!returns.isEmpty && returns.allSatisfy { $0.hasPrefix("dither(") },
                    "\(shader) returns a color that skips the dither: it bands in dark gradients")
        }
    }

    @Test func everyShaderCompilesAndDrawsAStillThatIsNotFlat() throws {
        guard let renderer = BackdropShaderRenderer() else { return } // a host without Metal
        for shader in BackdropShader.allCases {
            #expect(renderer.pipeline(shader) != nil, "\(shader) does not compile")
            for dark in [false, true] {
                let image = try #require(renderer.still(shader, width: 160, height: 100, dark: dark), "\(shader) drew no still")
                let lightness = Self.lightness(image)
                #expect(lightness.max - lightness.min > 0.03, "\(shader) \(dark ? "dark" : "light") is one flat color")
                #expect(dark ? lightness.mean < 0.45 : lightness.mean > 0.55,
                        "\(shader) \(dark ? "dark" : "light") averages \(lightness.mean): the wrong appearance")
            }
        }
    }

    @Test func thePosterIsRenderedOnFirstDecodeOffTheMainThread() async throws {
        guard BackdropShaderRenderer() != nil else { return }
        let url = BackdropShader.field.posterURL(dark: true)
        try? FileManager.default.removeItem(at: url)
        BackdropShaderRenderer.preparePoster(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path), "the main thread rendered a still")
        let image = await Task.detached { BackdropImageStore.decode(url, maxPixelSize: 400) }.value
        #expect(image != nil && FileManager.default.fileExists(atPath: url.path), "the first decode wrote no still")
    }

    struct Harness {
        let window: NSWindow
        let backdrop: WindowMaterialView
        var shader: BackdropShaderView { backdrop.shaderView }
        func close() { window.close() }
    }

    func make(_ selection: BackdropSelection, reduceMotion: Bool = false) -> Harness {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: frame)
        window.contentView = root
        let backdrop = WindowMaterialView(frame: frame, images: BackdropImageStore(maxPixelSize: 256))
        backdrop.shaderView.visibleOverride = true
        backdrop.shaderView.reduceMotionOverride = reduceMotion
        backdrop.shaderView.lowPowerOverride = false
        root.addSubview(backdrop)
        window.orderFrontRegardless()
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: selection), tint: .black)
        return Harness(window: window, backdrop: backdrop)
    }

    @Test func aShaderWallpaperDrawsBehindTheWindowAndMovesWhileSeen() {
        let h = make(.shader(.currents))
        defer { h.close() }
        #expect(h.shader.shader == .currents && !h.shader.isHidden)
        #expect(h.backdrop.showsShader && !h.backdrop.showsVideo)
        #expect(h.shader.moves || h.backdrop.shaderView.metalLayer.device == nil)
        // Another wallpaper hides it; the solid sheet never shows it.
        h.backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: nil), tint: .black)
        #expect(h.shader.shader == nil && h.shader.isHidden && !h.backdrop.showsShader)
        #expect(!h.shader.moves)
    }

    @Test func reduceMotionHoldsTheFrame() {
        let h = make(.shader(.aurora), reduceMotion: true)
        defer { h.close() }
        #expect(h.shader.shader == .aurora)
        #expect(!h.shader.moves, "Reduce Motion lets a living wallpaper move")
        h.shader.reduceMotionOverride = false
        #expect(h.shader.moves || h.backdrop.shaderView.metalLayer.device == nil)
        h.shader.visibleOverride = false
        #expect(!h.shader.moves, "a window no one can see keeps drawing")
    }

    @Test func thePointerIsEasedAndItsSpeedBecomesEnergyThatFades() {
        let h = make(.shader(.field))
        defer { h.close() }
        let view = h.shader
        view.pointerOverride = CGPoint(x: 10, y: 10)
        view.advance(by: 1 / 60)
        let start = view.currentUniforms
        view.pointerOverride = CGPoint(x: 300, y: 180)
        view.advance(by: 1 / 60)
        let moved = view.currentUniforms
        #expect(moved.energy > start.energy, "a fast pointer adds no energy")
        #expect(moved.mouse.x > start.mouse.x && moved.mouse.x < 300 * Float(view.pixelSize.width / view.bounds.width),
                "the shown pointer jumps instead of easing")
        for _ in 0..<120 { view.advance(by: 1 / 60) }
        #expect(view.currentUniforms.energy < moved.energy * 0.2, "the energy does not fade while the pointer rests")
        #expect(abs(view.currentUniforms.mouse.x - 300 * Float(view.pixelSize.width / view.bounds.width)) < 1,
                "the shown pointer never reaches the real one")
    }

    @Test func aResumeEasesTheClockUpFromStillInsteadOfJumpingToFullSpeed() {
        let h = make(.shader(.field))
        defer { h.close() }
        let view = h.shader
        view.resumed()
        let start = view.currentUniforms.time
        view.advance(by: 1 / 30)
        let first = view.currentUniforms.time - start
        #expect(first > 0 && first < Float(1.0 / 30) * 0.01, "a resume starts the clock at full speed")
        var steps: [Float] = []
        for _ in 0..<Int(BackdropShaderView.resumeRampSeconds * 30) {
            let before = view.currentUniforms.time
            view.advance(by: 1 / 30)
            steps.append(view.currentUniforms.time - before)
        }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $1 >= $0 - 1e-5 }, "the clock slows down during a resume")
        let before = view.currentUniforms.time
        view.advance(by: 1 / 30)
        #expect(abs(view.currentUniforms.time - before - Float(1.0 / 30)) < 1e-4, "the clock never reaches full speed")
        let total = view.currentUniforms.time - start
        let ramp = Float(BackdropShaderView.resumeRampSeconds)
        #expect(abs(total - (ramp / 2 + Float(2.0 / 30))) < 0.02, "the eased clock does not resume where it held")
    }

    /// ask-4b6ce9c1aa (Leo: "it doesnt actually follow the cursor"): the eased pointer lags a moving
    /// cursor by about 0.11 s, so a glow drawn there trails it. `pointer` is the cursor this frame,
    /// and Block Matrix centers its glow and core on it, keeping the eased one only for its trail.
    @Test func blockMatrixCentersOnThePointerThisFrameNotTheEasedOne() throws {
        let h = make(.shader(.matrix))
        defer { h.close() }
        let view = h.shader
        let scale = Float(view.pixelSize.width / view.bounds.width)
        view.pointerOverride = CGPoint(x: 10, y: 10)
        view.advance(by: 1 / 60)
        view.pointerOverride = CGPoint(x: 300, y: 180)
        view.advance(by: 1 / 60)
        let moved = view.currentUniforms
        #expect(abs(moved.pointer.x - 300 * scale) < 0.5 && abs(moved.pointer.y - 180 * scale) < 0.5,
                "the unsmoothed pointer is not where the cursor is this frame")
        #expect(moved.mouse.x < moved.pointer.x - 50 * scale, "the eased pointer no longer lags: the trail is gone")
        let source = BackdropShaderSource.source
        let start = try #require(source.range(of: "static float bmField("))
        let end = try #require(source.range(of: "fragment float4 wp_matrix(")).upperBound
        let rest = source[end...]
        let matrix = String(source[start.lowerBound..<end]) + String(rest[..<(rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex)])
        #expect(matrix.contains("float2 p = u.pointer / pitch;") && matrix.contains("bmGauss(x - u.pointer / pitch"),
                "Block Matrix centers its glow on the eased pointer: it trails the cursor")
        // The class: anything drawn under the cursor reads it this frame. Dot Field parts its dots there;
        // the fluid stirs (Currents, Ripples, Aurora, Aero's bubbles) keep the eased pointer as their inertia.
        let field = try #require(source.range(of: "fragment float4 wp_field("))
        let fieldBody = source[field.upperBound...].prefix(2000)
        #expect(fieldBody.contains("center - u.pointer"), "Dot Field parts its dots where the cursor was, not where it is")
    }

    @Test func clicksSendRingsAndTheOldestIsReplaced() {
        let h = make(.shader(.ripples))
        defer { h.close() }
        let view = h.shader
        for i in 0..<5 {
            view.advance(by: 0.1)
            view.ring(at: CGPoint(x: 20 * i, y: 40))
        }
        let rings = view.currentUniforms.ringList
        #expect(rings.allSatisfy { $0.w == 1 }, "a ring is not live")
        // The fifth click took the first click's slot.
        #expect(rings[0].x == Float(80) * Float(view.pixelSize.width / view.bounds.width))
        #expect(rings[0].z > rings[3].z, "the newest ring is not in the oldest slot")
    }

    /// The darkest, brightest and mean lightness (0...1) of `image`.
    static func lightness(_ image: CGImage) -> (min: Double, max: Double, mean: Double) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0, 0) }
        var low = 1.0, high = 0.0, sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let l = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
            low = min(low, l)
            high = max(high, l)
            sum += l
        }
        return (low, high, sum / Double(width * height))
    }
}
