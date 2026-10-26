import AVFoundation
@testable import CmuxNextAgentPane
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing

/// Leo, 2026-10-25: "also why dont we have previews of videos we should ... oh attaching a video
/// froze the composer". An attached video shows its poster and length, and the agent gets its key
/// frames: the host reads them with AVFoundation, off the main actor, and only for a video file of
/// a chat on this Mac inside its folders or home (``AgentPaneVideoInfo``, `video.info`). Quick Look
/// plays it on the person's click (`video.quickLook`).
@MainActor @Suite(.serialized)
struct AgentPaneVideoInfoTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-info-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A `seconds` long H.264 movie of `width`×`height` at 5 frames a second: red for its first
    /// half, blue for the rest. `rotated` gives its track a quarter turn, as a phone's portrait
    /// video has.
    nonisolated private static func movie(at url: URL, width: Int, height: Int, seconds: Int = 2, rotated: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        let rate = 5
        for index in 0..<(seconds * rate) {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let red = index < seconds * rate / 2
            for row in 0..<height {
                let line = base + row * CVPixelBufferGetBytesPerRow(pixels)
                for column in 0..<width {
                    // BGRA.
                    line[column * 4] = red ? 0 : 255
                    line[column * 4 + 1] = 0
                    line[column * 4 + 2] = red ? 255 : 0
                    line[column * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(rate))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }

    private static func image(_ base64: String) throws -> CGImage {
        let jpeg = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Whether `image`'s middle pixel is more red than blue.
    private static func isRed(_ image: CGImage) throws -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return pixel[0] > pixel[2]
    }

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func keyFramesAreTheMiddlesOfEqualParts() {
        #expect(AgentPaneVideoInfo.frameTimes(duration: 8, count: 4) == [1, 3, 5, 7])
        #expect(AgentPaneVideoInfo.frameTimes(duration: 0, count: 4).isEmpty)
        #expect(AgentPaneVideoInfo.frameTimes(duration: .nan, count: 4).isEmpty)
    }

    @Test func aVideoGivesItsLengthSizePosterAndFourSpreadFrames() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("Screen Recording.mov")
        try await Self.movie(at: clip, width: 1280, height: 720)

        let info = try #require(await AgentPaneVideoInfo.read(clip))
        #expect(abs(info.durationMs - 2000) <= 250, "\(info.durationMs)")
        #expect(info.width == 1280 && info.height == 720)
        // The poster is the chip's tile: at most 320 on its longest side, the video's shape.
        let poster = try Self.image(info.poster)
        #expect(poster.width == 320 && poster.height == 180)
        // Four frames, in order, inside the video, each at most 1024 wide: red first, blue last.
        #expect(info.frames.count == 4)
        #expect(info.frames.map(\.atMs) == info.frames.map(\.atMs).sorted())
        #expect(info.frames.allSatisfy { (0...info.durationMs).contains($0.atMs) })
        let frames = try info.frames.map { try Self.image($0.jpeg) }
        #expect(frames.allSatisfy { $0.width == 1024 && $0.height == 576 })
        #expect(try Self.isRed(frames[0]))
        #expect(try !Self.isRed(frames[3]))
        #expect(try Self.isRed(poster))
        let reply = info.reply
        #expect((reply["poster"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect((reply["frames"] as? [[String: Any]])?.count == 4)
    }

    @Test func aRotatedVideoShowsUpright() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("portrait.mov")
        try await Self.movie(at: clip, width: 320, height: 180, seconds: 1, rotated: true)

        let info = try #require(await AgentPaneVideoInfo.read(clip))
        #expect(info.width == 180 && info.height == 320)
        let poster = try Self.image(info.poster)
        #expect(poster.width < poster.height)
    }

    /// A reference movie: its own file holds only a header, and its media is `source`'s.
    nonisolated private static func referenceMovie(at url: URL, to source: URL) async throws {
        let original = AVURLAsset(url: source)
        let duration = try await original.load(.duration)
        let movie = AVMutableMovie()
        try movie.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: original, at: .zero, copySampleData: false)
        try movie.writeHeader(to: url, fileType: .mov, options: .truncateDestinationToMovieHeaderOnly)
    }

    @Test func aReferenceMovieNeverReadsTheMediaOfAnotherFile() async throws {
        // Leo's chat may read a movie in its folders, home or /tmp; one that only points at media
        // elsewhere (a secret folder, outside the roots) must not hand over that media's frames.
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appendingPathComponent("secret.mov")
        try await Self.movie(at: secret, width: 320, height: 180, seconds: 1)
        #expect(await AgentPaneVideoInfo.read(secret) != nil)
        let pointer = folder.appendingPathComponent("pointer.mov")
        try await Self.referenceMovie(at: pointer, to: secret)
        // The pointer is a real movie: opened the default way, its frames decode, from the secret's samples.
        let open = AVAssetImageGenerator(asset: AVURLAsset(url: pointer))
        #expect((try? await open.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))) != nil)
        // The host reads the pointer's own file only: no frame of the secret's comes back.
        #expect(await AgentPaneVideoInfo.read(pointer) == nil)
        // Without the secret the pointer shows nothing even opened the default way: its media was the secret's.
        try FileManager.default.removeItem(at: secret)
        let gone = AVAssetImageGenerator(asset: AVURLAsset(url: pointer))
        #expect((try? await gone.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))) == nil)
    }

    @Test func quickLookNeverPlaysAReferenceMovie() async throws {
        // Quick Look opens a movie with no reference restrictions: a pointer would play the secret's media.
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let secret = folder.appendingPathComponent("secret.mov")
        try await Self.movie(at: secret, width: 320, height: 180, seconds: 1)
        let clip = desktop.appendingPathComponent("clip.mov")
        try await Self.movie(at: clip, width: 320, height: 180, seconds: 1)
        let pointer = desktop.appendingPathComponent("pointer.mov")
        try await Self.referenceMovie(at: pointer, to: secret)
        #expect(await AgentPaneVideoInfo.isSelfContained(clip))
        #expect(await !AgentPaneVideoInfo.isSelfContained(pointer))

        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.home = home.path
        model.replyLinks.videoFolder = folder.appendingPathComponent("videos", isDirectory: true)
        var looked: [URL] = []
        model.replyLinks.quickLookFile = { looked.append($0) }
        model.transport.gestures.record(click: true)
        #expect(Self.errorCode(await Self.ask(model, "video.quickLook", ["src": pointer.path])) == AgentPaneReplyError.mediaRefused.rawValue)
        #expect(looked.isEmpty)
        model.transport.gestures.record(click: true)
        #expect(Self.errorCode(await Self.ask(model, "video.quickLook", ["src": clip.path])) == nil)
        #expect(looked.count == 1)
        // It plays the clip's copy, which a later rewrite of the clip into a pointer never reaches.
        let shown = try #require(looked.first)
        #expect(shown != clip && shown.lastPathComponent == "clip.mov")
        try Data(contentsOf: pointer).write(to: clip)
        #expect(await AgentPaneVideoInfo.isSelfContained(shown))
    }

    @Test func whatIsReadAndPlayedIsAPrivateCopyTakenFromTheFileAsItWasOpened() async throws {
        // A path is never read again after its check: the copy comes from the file opened once, so
        // one rewritten in place (into a reference movie), replaced, or reached through a folder
        // swapped for a link to `.ssh` afterwards changes nothing of what is read or played.
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let stage = home.appendingPathComponent("stage", isDirectory: true)
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        for dir in [stage, ssh] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let clip = stage.appendingPathComponent("clip.mov")
        try await Self.movie(at: clip, width: 320, height: 180, seconds: 1)
        let secret = folder.appendingPathComponent("secret.mov")
        try await Self.movie(at: secret, width: 640, height: 360, seconds: 1)
        let pointer = folder.appendingPathComponent("pointer.mov")
        try await Self.referenceMovie(at: pointer, to: secret)
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.home = home.path
        let videos = folder.appendingPathComponent("videos", isDirectory: true)
        model.replyLinks.videoFolder = videos

        let copy = try #require(await model.videoSnapshot(clip.path))
        #expect(copy.path.hasPrefix(videos.path + "/") && copy.lastPathComponent == "clip.mov")
        let bytes = try Data(contentsOf: clip)
        #expect(try Data(contentsOf: copy) == bytes)
        // The file rewritten in place into a reference movie: the copy is still the clip.
        try Data(contentsOf: pointer).write(to: clip)
        #expect(!(await AgentPaneVideoInfo.isSelfContained(clip)))
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(await AgentPaneVideoInfo.isSelfContained(copy))
        #expect(await AgentPaneVideoInfo.read(copy)?.width == 320)
        await AgentPaneVideoInfo.discard(copy)
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))

        // The folder a link to `.ssh`, which holds a movie of the same name: refused.
        try FileManager.default.removeItem(at: clip)
        try await Self.movie(at: ssh.appendingPathComponent("clip.mov"), width: 320, height: 180, seconds: 1)
        try FileManager.default.removeItem(at: stage)
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: ssh)
        #expect(await model.videoSnapshot(clip.path) == nil)
        #expect(Self.errorCode(await Self.ask(model, "video.info", ["src": clip.path])) == AgentPaneReplyError.mediaRefused.rawValue)
        // A read leaves no copy behind; a refusal makes none.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: videos.path)) ?? []).isEmpty)

        // A chat on another machine gets no copy.
        try FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try await Self.movie(at: clip, width: 320, height: 180, seconds: 1)
        model.remoteChat = true
        #expect(await model.videoSnapshot(clip.path) == nil)
    }

    @Test func aFileThatIsNotAVideoGivesNothing() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("notes.mov")
        try Data("not a movie".utf8).write(to: fake)
        #expect(await AgentPaneVideoInfo.read(fake) == nil)
        #expect(await AgentPaneVideoInfo.read(folder) == nil)
    }

    @Test func theHostReadsOnlyAVideoOfAChatOnThisMacInsideItsFoldersOrHome() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let project = folder.appendingPathComponent("project", isDirectory: true)
        for dir in [desktop, project, home.appendingPathComponent(".ssh", isDirectory: true)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let clip = desktop.appendingPathComponent("Screen Recording 2026-10-25.mov")
        try await Self.movie(at: clip, width: 320, height: 180, seconds: 1)
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.home = home.path
        model.workspaceRoots = { [project.path] }
        let videos = folder.appendingPathComponent("videos", isDirectory: true)
        model.replyLinks.videoFolder = videos
        var looked: [URL] = []
        model.replyLinks.quickLookFile = { looked.append($0) }

        // A recording on the Desktop (home, outside the project): its info, as a file URL too.
        for src in [clip.path, clip.absoluteString] {
            let reply = await Self.ask(model, "video.info", ["src": src])
            #expect(Self.errorCode(reply) == nil, "\(reply)")
            let value = try #require(reply["value"] as? [String: Any])
            #expect(value["width"] as? Int == 320 && value["height"] as? Int == 180)
            #expect((value["frames"] as? [[String: Any]])?.count == 4)
        }

        // Not a video by its name, on the deny list, outside home and the folders, missing, or a
        // chat on another machine: refused, and nothing read.
        let notes = desktop.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: notes)
        let secret = home.appendingPathComponent(".ssh/clip.mov")
        try FileManager.default.copyItem(at: clip, to: secret)
        let outside = folder.appendingPathComponent("outside.mov")
        try FileManager.default.copyItem(at: clip, to: outside)
        for src in [notes.path, secret.path, outside.path, desktop.appendingPathComponent("gone.mov").path, desktop.path] {
            let reply = await Self.ask(model, "video.info", ["src": src])
            #expect(Self.errorCode(reply) == AgentPaneReplyError.mediaRefused.rawValue, "\(src): \(reply)")
        }
        model.remoteChat = true
        #expect(Self.errorCode(await Self.ask(model, "video.info", ["src": clip.path])) == AgentPaneReplyError.mediaRefused.rawValue)
        model.remoteChat = false

        // Quick Look plays it on a click only, and only a video the host would read. The click is
        // spent before the file is checked: a request waiting on the disk never takes a later one.
        #expect(Self.errorCode(await Self.ask(model, "video.quickLook", ["src": clip.path])) == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(looked.isEmpty)
        model.transport.gestures.record(click: true)
        #expect(Self.errorCode(await Self.ask(model, "video.quickLook", ["src": outside.path])) == AgentPaneReplyError.mediaRefused.rawValue)
        #expect(Self.errorCode(await Self.ask(model, "video.quickLook", ["src": clip.path])) == AgentPaneReplyError.gestureRequired.rawValue)
        model.transport.gestures.record(click: true)
        let played = await Self.ask(model, "video.quickLook", ["src": clip.path])
        #expect(Self.errorCode(played) == nil, "\(played)")
        // Its copy, not the file itself.
        let shown = try #require(looked.first)
        #expect(looked.count == 1 && shown.path.hasPrefix(videos.path + "/"))
        #expect(try Data(contentsOf: shown) == Data(contentsOf: clip))
    }

    @Test func aVideoInTheChatsSessionFolderIsReadWithTheFolderMadeCanonicalOffTheMainActor() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let worktree = folder.appendingPathComponent("worktree", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        for dir in [worktree, home] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let clip = worktree.appendingPathComponent("demo.mp4")
        try await Self.movie(at: clip, width: 320, height: 180, seconds: 1)
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.home = home.path
        model.transport.sessions.observeFolder(["result": ["session": ["sessionId": "s", "cwd": worktree.path]]], replyTo: "_acpmux/attach")

        // The folder acpmux reported is the chat's only once the pane shows that session and has it.
        #expect(Self.errorCode(await Self.ask(model, "video.info", ["src": clip.path])) == AgentPaneReplyError.mediaRefused.rawValue)
        model.adoptSession("s")
        #expect(Self.errorCode(await Self.ask(model, "video.info", ["src": clip.path])) == AgentPaneReplyError.mediaRefused.rawValue)
        model.transport.sessions.add("s")
        let scope = model.replyPathScope()
        #expect(scope.session == worktree.path)
        let reply = await Self.ask(model, "video.info", ["src": clip.path])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        // A path relative to it starts there; the scope's paths are the ones `replyPaths()` gave before.
        #expect(Self.errorCode(await Self.ask(model, "video.info", ["src": "demo.mp4"])) == nil)
        let canonical = try #require(AcpmuxPathPolicy.canonical(worktree.path))
        #expect(model.replyPaths().roots.contains(canonical))
        #expect(model.replyPaths().base == canonical)
        // Never `/` or the home folder as a root (`sessionRoots`): the workspace's root is the base then.
        let workspace = AgentPanePrimaryRoot(answered: true, candidates: ["/w"])
        for cwd in ["/", NSHomeDirectory()] {
            let paths = AgentPaneReplyPaths(.init(local: true, roots: [], session: cwd, primary: workspace, home: home.path))
            #expect(paths.roots.isEmpty && paths.base == "/w", "\(cwd)")
        }
        #expect(AgentPaneReplyPaths(.init(local: false, roots: [worktree.path], session: worktree.path, primary: workspace, home: home.path)).roots.isEmpty)
        // The workspace root is chosen as `primaryRoot()` chose it: never home or above, nor an agent-home folder.
        let agentHome = AgentHome(base: folder.appendingPathComponent("agent-home").path)
        let choice = AgentPanePrimaryRoot(answered: false, candidates: ["/", home.path, agentHome.base + "/w1", worktree.path],
                                          home: home.path, agentHome: agentHome)
        #expect(choice.resolve() == worktree.path)
        #expect(AgentPanePrimaryRoot(answered: true, candidates: []).resolve() == nil)
    }

    @Test func theRequestsTakeOnlyTheirSource() {
        #expect(AgentPaneReplyRequest(method: "video.info", params: ["src": "/a.mov"]) == .videoInfo("/a.mov"))
        #expect(AgentPaneReplyRequest(method: "video.quickLook", params: ["src": "/a.mov"]) == .quickLookVideo("/a.mov"))
        #expect(AgentPaneReplyRequest(method: "video.info", params: ["src": "/a.mov", "frames": 9]) == nil)
        #expect(AgentPaneReplyRequest(method: "video.info", params: [:]) == nil)
        #expect(AgentPaneReplyRequest.videoInfo("/a.mov").isPassive)
        #expect(!AgentPaneReplyRequest.quickLookVideo("/a.mov").isPassive)
        #expect(AgentPageOps.method(for: "cmux.agent.video.info") == "video.info")
        #expect(AgentPageOps.method(for: "cmux.agent.video.quickLook") == "video.quickLook")
    }
}
