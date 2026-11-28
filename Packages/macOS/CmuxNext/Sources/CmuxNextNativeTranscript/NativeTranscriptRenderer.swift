#if canImport(CCmuxNativeTranscriptFFI)
import CCmuxNativeTranscriptFFI
import CmuxNextCompat
import Foundation
import Metal
import QuartzCore

/// The render-thread half of one native transcript (RFD 0121): it owns the Rust scene, the glyph atlas, the rich
/// rows and the instance buffers, and draws one frame per display link tick on its own thread
/// (``NativeTranscriptThread``). Everything else reaches it through `post`, drained at the start of each tick, so
/// the scene is only ever touched on this thread (the header's rule).
///
/// A frame: the posted input, the glyphs the last frame placed (CoreText into the atlas), the rich rows the scene
/// asks for ahead of the viewport (made off this thread), then `cmux_nt_frame` writes the visible quads straight
/// into a shared Metal buffer and one instanced draw covers every glyph, fill and texture quad. Three buffers rotate;
/// a tick that finds all three on the GPU draws nothing and is counted (`skipped`).
// crash-allow: every var below is touched on the render thread only (made there in `make`, used from `tick` and posted closures); `inbox` and `presented` are Mutexes; `layer` is configured on main before the first tick, then touched only here.
nonisolated final class NativeTranscriptRenderer: @unchecked Sendable {
    typealias Command = @Sendable (NativeTranscriptRenderer) -> Void
    static let rows: UInt32 = 3000
    private static let buffers = 3
    private let layer: CAMetalLayer
    private let gpu: NativeTranscriptGPU
    private let atlas: NativeTranscriptAtlas
    private let rich: NativeTranscriptRichRows
    private let scene: OpaquePointer
    private var size: CGSize
    private var scale: CGFloat
    private var instanceBuffers: [any MTLBuffer] = []
    private var capacity: UInt32 = 16384
    private var next = 0
    // concurrency-allow: counts the instance buffers the GPU still reads; the render thread only polls it (timeout now), never waits.
    private let inFlight = DispatchSemaphore(value: buffers)
    // concurrency-allow: the commands other threads post; drained at the top of each tick; no work under the lock.
    private let inbox = Mutex<[Command]>([])
    // concurrency-allow: presentation times Metal's presented handlers add on its thread; the stats read them; no I/O under it.
    private let presented = Mutex(NativeTranscriptPresented())
    private(set) var last = CmuxNtFrameInfo()
    private(set) var skipped = 0
    private(set) var quadsMax: UInt32 = 0
    private(set) var refreshMs = 1000.0 / 120

    /// Makes the GPU objects and the 3,000-row fixture scene for a `size`-point viewport at `scale`. Render thread.
    static func make(layer: CAMetalLayer, size: CGSize, scale: CGFloat) -> NativeTranscriptRenderer? {
        guard let gpu = NativeTranscriptGPU.make(pixelFormat: layer.pixelFormat),
              let atlas = NativeTranscriptAtlas(device: gpu.device, scale: scale) else { return nil }
        var metrics = atlas.metrics
        guard let scene = cmux_nt_scene_new_fixture(rows, Float(size.width), Float(size.height), &metrics) else { return nil }
        return NativeTranscriptRenderer(layer: layer, gpu: gpu, atlas: atlas, scene: scene, size: size, scale: scale)
    }

    private init(layer: CAMetalLayer, gpu: NativeTranscriptGPU, atlas: NativeTranscriptAtlas, scene: OpaquePointer,
                 size: CGSize, scale: CGFloat) {
        self.layer = layer
        self.gpu = gpu
        self.atlas = atlas
        self.scene = scene
        self.size = size
        self.scale = scale
        rich = NativeTranscriptRichRows(device: gpu.device, scale: scale)
        layer.device = gpu.device
        makeBuffers()
    }

    deinit { cmux_nt_scene_free(scene) }

    /// Queues `command` for the next tick (any thread).
    func post(_ command: @escaping Command) { inbox.withLock { $0.append(command) } }

    // MARK: Input (render thread, from posted commands)

    func resize(_ newSize: CGSize, scale: CGFloat) {
        self.scale = scale
        guard newSize != size, newSize.width > 0, newSize.height > 0 else { return }
        size = newSize
        cmux_nt_set_viewport(scene, Float(newSize.width), Float(newSize.height))
    }

    func fling(velocity: Double) {
        presented.withLock { $0.reset() }
        cmux_nt_fling(scene, velocity, CACurrentMediaTime())
    }

    func scroll(to offset: Double) { cmux_nt_scroll_to(scene, offset) }
    func scroll(by delta: Double) { cmux_nt_scroll_by(scene, delta) }

    func resetStats() {
        cmux_nt_stats_reset(scene)
        presented.withLock { $0.reset() }
        skipped = 0
        quadsMax = 0
    }

    /// The scene's frame record and this host's own: presentation intervals while flinging, frames skipped, the
    /// atlas and rich-row counts.
    func stats() -> [String: Double] {
        var record = CmuxNtStats()
        cmux_nt_stats(scene, &record)
        let shown = presented.withLock { $0.summary(refreshMs: refreshMs) }
        var out: [String: Double] = [
            "frames": Double(record.frames), "late_texture_frames": Double(record.late_texture_frames),
            "late_textures": Double(record.late_textures), "interval_p50_ms": record.interval_p50_ms,
            "interval_p95_ms": record.interval_p95_ms, "interval_max_ms": record.interval_max_ms,
            "build_p50_us": record.build_p50_us, "build_p95_us": record.build_p95_us, "build_max_us": record.build_max_us,
            "intervals_over_8_33": Double(record.intervals_over_8_33),
            "skipped_frames": Double(skipped), "quads_max": Double(quadsMax), "glyphs_rasterized": Double(atlas.rasterized),
            "textures_made": Double(rich.made), "textures_evicted": Double(rich.evicted), "refresh_ms": refreshMs,
            "offset": last.offset, "content_height": last.content_height, "flinging": last.flinging ? 1 : 0,
            "first_row": Double(last.first_row), "last_row": Double(last.last_row),
        ]
        for (key, value) in shown { out["presented_" + key] = value }
        return out
    }

    // MARK: Frames (render thread)

    /// One display frame at the link's target time `now`; `refresh` is the link's frame duration in seconds.
    // perf-hot: 2ms native-transcript-frame (drain input, fill glyphs, ask rich rows, build quads, encode, present)
    func tick(now: Double, refresh: Double) {
        if refresh > 0 { refreshMs = refresh * 1000 }
        for command in inbox.withLock({ commands -> [Command] in defer { commands.removeAll() }; return commands }) {
            command(self)
        }
        atlas.fill(scene)
        rich.request(scene) { [weak self] id, row, made in
            self?.post { renderer in
                let shown = renderer.last.first_row...max(renderer.last.first_row, renderer.last.last_row)
                renderer.rich.deliver(renderer.scene, id: id, row: row, texture: made.texture, visible: shown)
            }
        }
        // A poll with timeout now on the render thread (never main): it never blocks.
        guard inFlight.blockingWait(timeout: .now()) == .success else {
            skipped += 1
            return
        }
        let buffer = instanceBuffers[next]
        next = (next + 1) % instanceBuffers.count
        let quads = buffer.contents().bindMemory(to: CmuxNtQuad.self, capacity: Int(capacity))
        var info = CmuxNtFrameInfo()
        let count = cmux_nt_frame(scene, now, quads, capacity, &info)
        last = info
        quadsMax = max(quadsMax, info.quads_needed)
        for index in 0..<Int(count) where quads[index].kind == UInt32(CMUX_NT_QUAD_TEXTURE) {
            quads[index].texture_id = rich.slot(for: quads[index].texture_id)
        }
        if info.quads_needed > capacity {
            // The next frame gets every quad: grow once to the next power of two over what this one needed.
            capacity = UInt32(1) << UInt32(64 - UInt64(info.quads_needed).leadingZeroBitCount)
            post { $0.makeBuffers() }
        }
        guard encode(buffer, count: Int(count), flinging: info.flinging) else {
            inFlight.signal()
            skipped += 1
            return
        }
    }

    private func encode(_ buffer: any MTLBuffer, count: Int, flinging: Bool) -> Bool {
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if layer.drawableSize != pixels {
            // An explicit transaction: the render thread's run loop does not commit an implicit one before the draw.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.drawableSize = pixels
            CATransaction.commit()
        }
        guard let drawable = layer.nextDrawable(), let commands = gpu.queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.07, green: 0.075, blue: 0.09, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if count > 0 {
            var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
            encoder.setRenderPipelineState(gpu.pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            rich.bind(encoder, clear: gpu.clear)
            encoder.setFragmentSamplerState(gpu.sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        encoder.endEncoding()
        if flinging {
            drawable.addPresentedHandler { [weak self] shown in
                let at = shown.presentedTime
                guard at > 0 else { return }
                self?.presented.withLock { $0.add(at) }
            }
        }
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.present(drawable)
        commands.commit()
        return true
    }

    private func makeBuffers() {
        let length = Int(capacity) * MemoryLayout<CmuxNtQuad>.stride
        instanceBuffers = (0..<Self.buffers).compactMap { _ in gpu.device.makeBuffer(length: length, options: .storageModeShared) }
        next = 0
    }
}

/// The presentation times of the frames drawn while flinging (``CAMetalDrawable/presentedTime``), and their
/// intervals: what reached the glass, which the scene's own record (`cmux_nt_frame`'s clock) cannot see.
nonisolated struct NativeTranscriptPresented: Sendable {
    private static let cap = 20000
    private var times: [Double] = []

    mutating func add(_ time: Double) { if times.count < Self.cap { times.append(time) } }
    mutating func reset() { times.removeAll(keepingCapacity: true) }

    func summary(refreshMs: Double) -> [String: Double] {
        let sorted = times.sorted()
        let intervals = zip(sorted.dropFirst(), sorted).map { ($0 - $1) * 1000 }.filter { $0 > 0.5 }.sorted()
        guard !intervals.isEmpty else { return ["frames": Double(times.count)] }
        func at(_ q: Double) -> Double { intervals[min(intervals.count - 1, Int((Double(intervals.count - 1) * q).rounded()))] }
        return ["frames": Double(times.count), "interval_p50_ms": at(0.5), "interval_p95_ms": at(0.95),
                "interval_max_ms": intervals.last ?? 0,
                "intervals_over_1_5_refresh": Double(intervals.filter { $0 > refreshMs * 1.5 }.count)]
    }
}
#endif
