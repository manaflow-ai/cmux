#if canImport(CCmuxNativeTranscriptFFI)
import CCmuxNativeTranscriptFFI
import CoreGraphics
import CoreText
import Foundation
import Metal

/// The rich rows of one native transcript: the textures the scene asks for ahead of the viewport
/// (`cmux_nt_take_texture_requests`), made off the render thread, and the slots they are bound to in the draw.
///
/// The fixture's rich row is a KaTeX block; until the real math renderer is native, its picture is a placeholder
/// raster with the same cost shape: a CoreText line set into a bitmap of the row's size at the display's scale, one
/// texture upload. `make` runs on `queue` (utility); the finished texture comes back to the render thread through
/// `deliver`, which binds it to a free slot (evicting the resident row farthest from the viewport, and telling the
/// scene it was released) and only then marks it ready.
// crash-allow: `slots`, `slotOf` and `pending` only on the render thread; `queue` work touches only its own locals and the thread-safe MTLDevice.
nonisolated final class NativeTranscriptRichRows: @unchecked Sendable {
    /// Rows ahead of (and behind) the viewport the scene asks textures for.
    static let prefetchRows: UInt32 = 60
    /// Textures being made at once.
    static let inFlightCap = 8
    private struct Resident { var id: UInt32; var row: UInt32; var texture: any MTLTexture }
    private let device: any MTLDevice
    private let scale: CGFloat
    private let queue = DispatchQueue(label: "cmux-next.native-transcript.rich-rows", qos: .utility)
    private var slots: [Resident?] = Array(repeating: nil, count: NativeTranscriptGPU.richSlots - 1)
    private var slotOf: [UInt32: Int] = [:]
    private var pending = 0
    private var requests = [CmuxNtTextureRequest](repeating: CmuxNtTextureRequest(), count: 16)
    private(set) var made = 0
    private(set) var evicted = 0

    init(device: any MTLDevice, scale: CGFloat) {
        self.device = device
        self.scale = scale
    }

    /// The slot a texture quad of `id` samples: its bound slot, else the clear one.
    func slot(for id: UInt32) -> UInt32 { UInt32(slotOf[id] ?? (NativeTranscriptGPU.richSlots - 1)) }

    func bind(_ encoder: any MTLRenderCommandEncoder, clear: any MTLTexture) {
        var textures: [(any MTLTexture)?] = slots.map { $0?.texture ?? clear }
        textures.append(clear)
        encoder.setFragmentTextures(textures, range: 1..<(1 + textures.count))
    }

    /// Takes the scene's new requests (as many as fit in flight) and starts them on `queue`. `deliver` posts the
    /// finished texture back to the render thread.
    func request(_ scene: OpaquePointer, deliver: @escaping @Sendable (UInt32, UInt32, NativeTranscriptTexture) -> Void) {
        let room = min(requests.count, Self.inFlightCap - pending)
        guard room > 0 else { return }
        let count = Int(requests.withUnsafeMutableBufferPointer {
            cmux_nt_take_texture_requests(scene, Self.prefetchRows, $0.baseAddress, UInt32(room))
        })
        for index in 0..<count {
            let request = requests[index]
            pending += 1
            let device = device, scale = scale
            queue.async {
                deliver(request.texture_id, request.row, NativeTranscriptTexture(Self.make(request, device: device, scale: scale)))
            }
        }
    }

    /// On the render thread: a texture made for `id` (row `row`). Binds it and tells the scene it is ready; a
    /// failed make tells the scene it is not, so it asks again.
    func deliver(_ scene: OpaquePointer, id: UInt32, row: UInt32, texture: (any MTLTexture)?, visible: ClosedRange<UInt32>) {
        pending = max(0, pending - 1)
        guard let texture else {
            cmux_nt_texture_ready(scene, id, false)
            return
        }
        let slot: Int
        if let bound = slotOf[id] {
            slot = bound
        } else if let free = slots.firstIndex(where: { $0 == nil }) {
            slot = free
        } else {
            // The resident row farthest from the viewport goes; the scene asks for it again when it comes near.
            func distance(_ row: UInt32) -> UInt32 {
                row < visible.lowerBound ? visible.lowerBound - row : row > visible.upperBound ? row - visible.upperBound : 0
            }
            let far = slots.indices.max { distance(slots[$0]?.row ?? 0) < distance(slots[$1]?.row ?? 0) } ?? 0
            if let old = slots[far] {
                slotOf[old.id] = nil
                cmux_nt_texture_ready(scene, old.id, false)
                evicted += 1
            }
            slot = far
        }
        slots[slot] = Resident(id: id, row: row, texture: texture)
        slotOf[id] = slot
        made += 1
        cmux_nt_texture_ready(scene, id, true)
    }

    /// The placeholder raster of a rich row: a light block with a formula-like line, at the row's pixel size.
    // perf-hot: 4ms native-transcript-rich-row (one rich row's picture, off the render thread)
    private static func make(_ request: CmuxNtTextureRequest, device: any MTLDevice, scale: CGFloat) -> (any MTLTexture)? {
        let width = max(1, Int((CGFloat(request.w) * scale).rounded(.up)))
        let height = max(1, Int((CGFloat(request.h) * scale).rounded(.up)))
        guard width <= 16384, height <= 16384 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.scaleBy(x: scale, y: scale)
            let box = CGRect(x: 0, y: 0, width: CGFloat(request.w), height: CGFloat(request.h))
            context.setFillColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1)
            context.fill(box.insetBy(dx: 0, dy: 4))
            let formula = "\u{2211}_{k=1}^{\(request.row)} \u{222B} f(x)\u{00B7}e^{-ikx} dx = \u{03C0}\u{00B2}/6   [row \(request.row)]"
            let font = CTFontCreateWithName("Times New Roman" as CFString, 18, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                // A placeholder raster's ink, not UI chrome; the real math renderer replaces it.
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1), // colour-allow: placeholder ink
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: formula, attributes: attributes))
            context.textPosition = CGPoint(x: 16, y: box.midY - 6)
            CTLineDraw(line, context)
            return true
        }
        guard drew else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "native transcript rich row \(request.row)"
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4)
        }
        return texture
    }
}

/// A made rich-row texture on its way from the maker's queue to the render thread.
// crash-allow: the texture is written once on the maker's queue before it is handed over, then only read by the render thread and the GPU.
nonisolated struct NativeTranscriptTexture: @unchecked Sendable {
    let texture: (any MTLTexture)?
    init(_ texture: (any MTLTexture)?) { self.texture = texture }
}
#endif
