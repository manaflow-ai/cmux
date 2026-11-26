public import CmuxTheme
public import Foundation
import Metal

/// The GPU every live wallpaper draws on: the system's default device and one command queue,
/// made once, with the scene engine's fixed bindings. Metal's device, command queue, sampler
/// states and textures that nothing writes are safe to use from any thread.
// crash-allow: immutable after init; MTLDevice, MTLCommandQueue and MTLSamplerState are documented thread-safe, and the clear texture is written once, in init, before it is shared.
nonisolated final class LiveWallpaperGPU: @unchecked Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    /// The scene engine's image sampler (fragment sampler 0); nil when Metal made none.
    let sceneSampler: (any MTLSamplerState)?
    /// The 1x1 clear texture a scene binds at fragment texture 0 when it shows no image; nil when Metal made none.
    let sceneClear: (any MTLTexture)?
    /// The drawables' and stills' format: 8-bit, not sRGB (the program's epilogue encodes sRGB).
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// The app's GPU; nil on a Mac without Metal (no live wallpaper draws there).
    static let shared: LiveWallpaperGPU? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return LiveWallpaperGPU(device: device, queue: queue)
    }()

    private init(device: any MTLDevice, queue: any MTLCommandQueue) {
        self.device = device
        self.queue = queue
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        sceneSampler = device.makeSamplerState(descriptor: sampler)
        sceneClear = LiveWallpaperSceneImage.texture(pixels: [0, 0, 0, 0], width: 1, height: 1, device: device)
    }
}

/// One wallpaper's render pipeline (its `vs_main` and `fs_main` into ``LiveWallpaperGPU/pixelFormat``).
// crash-allow: immutable after init; MTLRenderPipelineState is documented thread-safe.
nonisolated final class LiveWallpaperPipeline: @unchecked Sendable {
    let state: any MTLRenderPipelineState

    init(_ state: any MTLRenderPipelineState) {
        self.state = state
    }
}

/// The app's live wallpaper programs (one, ``BackdropImageStore/livePrograms``): each wallpaper's
/// Metal program built once per id and source digest, off the main thread: the library from the
/// build-time MSL (`cmux_wallpaper_first_party_msl`), then the pipeline, both through Metal's
/// asynchronous calls (the compiler service never blocks a thread of ours). Callers that ask while
/// a build runs join it. A program Metal refuses stays refused (nil), and the view draws nothing
/// for it. It also owns the render queue every view draws on, and the picker's stills.
public actor LiveWallpaperPrograms {
    /// The one render queue of every live wallpaper (plans/cmux-next/threading-model.md, Design):
    /// `nextDrawable`, encode and commit, off the main thread.
    nonisolated let renderQueue = DispatchQueue(label: "com.cmuxterm.next.live-wallpaper.render", qos: .userInitiated)
    private var builds: [String: Task<LiveWallpaperPipeline?, Never>] = [:]
    /// The picker's stills as PNG, by ``LiveWallpaper/stillKey(tokens:)`` and size.
    private var stills: [String: Data] = [:]
    /// Why a program did not build, by id (`debug.themes` reads it through the view).
    private var failures: [String: String] = [:]

    public init() {}

    /// `wallpaper`'s pipeline, building it the first time. Every motion scene shares one: the scene
    /// engine's (``LiveWallpaper/programKey``), so its library is built once for the app.
    func pipeline(for wallpaper: LiveWallpaper) async -> LiveWallpaperPipeline? {
        let key = wallpaper.programKey
        if let running = builds[key] { return await running.value }
        // task-owner: one build per program for the process; kept so later callers join it
        let build = Task.detached(priority: .medium) { [self] () -> LiveWallpaperPipeline? in
            switch await Self.build(wallpaper) {
            case .success(let pipeline): return pipeline
            case .failure(let error):
                await recordFailure(wallpaper.id, error)
                return nil
            }
        }
        builds[key] = build
        return await build.value
    }

    /// Why `id`'s program did not build; nil when it built or was never asked for.
    func failure(for id: String) -> String? { failures[id] }

    /// `wallpaper`'s still in `tokens`' colors at `width` x `height` pixels as PNG (the picker's
    /// thumbnail), drawn once per wallpaper, program, colors and size.
    public func stillPNG(_ wallpaper: LiveWallpaper, width: Int, height: Int, tokens: ThemeTokens) async -> Data? {
        let key = "\(wallpaper.stillKey(tokens: tokens))|\(width)x\(height)"
        if let data = stills[key] { return data }
        guard let data = await wallpaper.still(width: width, height: height, tokens: tokens, programs: self)?.pngData() else { return nil }
        stills[key] = data
        return data
    }

    private func recordFailure(_ id: String, _ error: LiveWallpaperBuildError) {
        failures[id] = error.description
    }

    @concurrent
    private static func build(_ wallpaper: LiveWallpaper) async -> Result<LiveWallpaperPipeline, LiveWallpaperBuildError> {
        guard let gpu = LiveWallpaperGPU.shared else { return .failure(.noGPU) }
        guard let source = wallpaper.metalSource else { return .failure(.noProgram) }
        let library: LiveWallpaperLibrary
        do {
            library = try await withCheckedThrowingContinuation { continuation in
                gpu.device.makeLibrary(source: source, options: MTLCompileOptions()) { made, error in
                    if let made {
                        continuation.resume(returning: LiveWallpaperLibrary(made))
                    } else {
                        continuation.resume(throwing: LiveWallpaperBuildError.library(error.map { "\($0)" } ?? "no library"))
                    }
                }
            }
        } catch let error as LiveWallpaperBuildError {
            return .failure(error)
        } catch {
            return .failure(.library("\(error)"))
        }
        guard let vertex = library.value.makeFunction(name: "vs_main"),
              let fragment = library.value.makeFunction(name: "fs_main") else { return .failure(.entryPoints) }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = wallpaper.isScene ? "live-wallpaper.scene-engine" : "live-wallpaper.\(wallpaper.id)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = LiveWallpaperGPU.pixelFormat
        do {
            return .success(try await withCheckedThrowingContinuation { continuation in
                gpu.device.makeRenderPipelineState(descriptor: descriptor) { state, error in
                    if let state {
                        continuation.resume(returning: LiveWallpaperPipeline(state))
                    } else {
                        continuation.resume(throwing: LiveWallpaperBuildError.pipeline(error.map { "\($0)" } ?? "no pipeline"))
                    }
                }
            })
        } catch let error as LiveWallpaperBuildError {
            return .failure(error)
        } catch {
            return .failure(.pipeline("\(error)"))
        }
    }
}

/// A built library handed from Metal's completion thread to the build.
// crash-allow: immutable after init; MTLLibrary is documented thread-safe.
private nonisolated final class LiveWallpaperLibrary: @unchecked Sendable {
    let value: any MTLLibrary

    init(_ value: any MTLLibrary) {
        self.value = value
    }
}

/// Why a wallpaper's program did not build.
nonisolated enum LiveWallpaperBuildError: Error, Sendable, CustomStringConvertible {
    case noGPU
    case noProgram
    case library(String)
    case entryPoints
    case pipeline(String)

    var description: String {
        switch self {
        case .noGPU: "no Metal device"
        case .noProgram: "the library carries no Metal program for it"
        case .library(let why): "Metal refused the program: \(why)"
        case .entryPoints: "the program has no vs_main or fs_main"
        case .pipeline(let why): "Metal refused the pipeline: \(why)"
        }
    }
}
