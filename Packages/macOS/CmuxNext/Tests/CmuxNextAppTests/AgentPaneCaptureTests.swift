@testable import CmuxNextAgentPane
import Foundation
import Testing

/// What `composer.capture` answers the page for what `screencapture` wrote: a capture named for
/// when it was taken (so two in one prompt differ), nothing for a cancelled pick, and a capture over
/// the scaling target as written, never refused for its size.
struct AgentPaneCaptureTests {
    private static let taken = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                              year: 2026, month: 10, day: 11, hour: 14, minute: 32, second: 5).date!

    @Test func aCaptureIsNamedForWhenItWasTaken() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let answer = AgentPaneCapture.answer(png, taken: Self.taken)
        #expect(answer["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["mimeType"] as? String == "image/png")
        #expect(answer["data"] as? String == png.base64EncodedString())
    }

    @Test func aCancelledPickAnswersNothingToAttach() {
        let answer = AgentPaneCapture.answer(Data(), taken: Self.taken)
        #expect(answer["cancelled"] as? Bool == true)
        #expect(answer["data"] == nil)
    }

    /// A stub `screencapture` in a fresh folder, the file it would write, and a cleanup.
    private static func stub(_ script: String) throws -> (tool: String, file: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tool = root.appendingPathComponent("screencapture-stub.sh")
        try "#!/bin/sh\n\(script)\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool.path, root.appendingPathComponent("capture.png"), root)
    }

    /// #20827: `screencapture` that fails (no Screen Recording grant, a crash) is not an Esc.
    @Test(.timeLimit(.minutes(1))) func aFailedScreencaptureIsAFailureNotACancel() async throws {
        let stub = try Self.stub(#"echo "could not create image from display" >&2; exit 1"#)
        defer { try? FileManager.default.removeItem(at: stub.root) }
        let result = await AgentPaneCapture.capture(window: false, to: stub.file, executable: stub.tool)
        guard case .failed = result else {
            Issue.record("a screencapture that exited 1 read as \(result)")
            return
        }
    }

    /// An error that `screencapture` reports with status 0 and no image is not an Esc either.
    @Test(.timeLimit(.minutes(1))) func anErrorSaidWithStatusZeroAndNoImageIsAFailure() async throws {
        let stub = try Self.stub(#"echo "could not create image from display" >&2; exit 0"#)
        defer { try? FileManager.default.removeItem(at: stub.root) }
        let result = await AgentPaneCapture.capture(window: false, to: stub.file, executable: stub.tool)
        guard case .failed = result else {
            Issue.record("an error said with status 0 read as \(result)")
            return
        }
    }

    /// An Esc in the pick exits 0 and writes nothing: still a cancel, not an error.
    @Test(.timeLimit(.minutes(1))) func anEscapedPickIsTakenWithNoImage() async throws {
        let stub = try Self.stub("exit 0")
        defer { try? FileManager.default.removeItem(at: stub.root) }
        #expect(await AgentPaneCapture.capture(window: false, to: stub.file, executable: stub.tool) == .taken)
        #expect(!FileManager.default.fileExists(atPath: stub.file.path))
    }

    /// An Esc that a macOS version reports with a nonzero status, writing and saying nothing, is
    /// still a cancel.
    @Test(.timeLimit(.minutes(1))) func aQuietNonzeroExitWithNoImageIsACancel() async throws {
        let stub = try Self.stub("exit 1")
        defer { try? FileManager.default.removeItem(at: stub.root) }
        #expect(await AgentPaneCapture.capture(window: false, to: stub.file, executable: stub.tool) == .taken)
    }

    /// A failed pick that left a partial file removes it (its bytes are the person's screen).
    @Test(.timeLimit(.minutes(1))) func aFailedPickLeavesNoFile() async throws {
        let stub = try Self.stub(#"printf partial > "$5"; exit 1"#)
        defer { try? FileManager.default.removeItem(at: stub.root) }
        _ = await AgentPaneCapture.capture(window: false, to: stub.file, executable: stub.tool)
        #expect(!FileManager.default.fileExists(atPath: stub.file.path), "the failed capture's file was left behind")
    }

    @Test func aCaptureOverTheCapIsAttachedAsWrittenNotRefused() {
        // Bytes over the cap that are no image: nothing can scale them under it, and they still go.
        let png = Data(count: AgentPaneCapture.maxBytes + 1)
        let answer = AgentPaneCapture.answer(png, taken: Self.taken)
        #expect(answer["tooLarge"] == nil)
        #expect(answer["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["mimeType"] as? String == "image/png")
        #expect(answer["data"] as? String == png.base64EncodedString())
    }

    // Record Screen… (Leo, 2026-11-07, ask-b640c4d6fa): the system toolbar's recording is kept for
    // the person and attached by its path; a still from the same toolbar is a screenshot.

    @Test func aRecordingOpensTheSystemToolbarInItsVideoModeShowingClicks() {
        let file = URL(fileURLWithPath: "/tmp/r.mov")
        #expect(AgentPaneCapture.arguments(for: .video, to: file) == ["-i", "-U", "-J", "video", "-k", "-x", "/tmp/r.mov"])
        // The stills keep their arguments (aFailedPickLeavesNoFile writes the screen pick's 5th).
        #expect(AgentPaneCapture.arguments(for: .screen, to: file) == ["-i", "-x", "-t", "png", "/tmp/r.mov"])
        #expect(AgentPaneCapture.arguments(for: .window, to: file) == ["-i", "-W", "-o", "-x", "-t", "png", "/tmp/r.mov"])
    }

    /// A fresh folder with `bytes` written where the toolbar would write them, and the folder kept recordings go to.
    private static func recorded(_ bytes: Data) throws -> (file: URL, folder: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-record-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("cmux-recording.mov")
        if !bytes.isEmpty { try bytes.write(to: file) }
        return (file, root.appendingPathComponent("Movies/cmux"), root)
    }

    /// A QuickTime file's opening atom: no image ImageIO reads.
    private static let movie = Data([0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20,
                                     0, 0, 0, 0, 0x71, 0x74, 0x20, 0x20, 0, 0, 0, 8, 0x77, 0x69, 0x64, 0x65])

    @Test func aRecordingIsKeptForThePersonAndAnsweredByItsPath() throws {
        let made = try Self.recorded(Self.movie)
        defer { try? FileManager.default.removeItem(at: made.root) }
        let answer = AgentPaneCapture.keepRecording(made.file, taken: Self.taken, in: made.folder)
        let kept = made.folder.appendingPathComponent("Screen Recording 2026-10-11 14.32.05.mov")
        #expect(answer["path"] as? String == kept.path)
        #expect(answer["name"] as? String == "Screen Recording 2026-10-11 14.32.05.mov")
        #expect(answer["mimeType"] as? String == "video/quicktime")
        #expect(answer["data"] == nil)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: made.file.path), "the temporary recording was left behind")
    }

    @Test func aSecondRecordingInTheSameSecondKeepsTheFirst() throws {
        let first = try Self.recorded(Self.movie)
        defer { try? FileManager.default.removeItem(at: first.root) }
        _ = AgentPaneCapture.keepRecording(first.file, taken: Self.taken, in: first.folder)
        try Self.movie.write(to: first.file)
        let answer = AgentPaneCapture.keepRecording(first.file, taken: Self.taken, in: first.folder)
        #expect(answer["name"] as? String == "Screen Recording 2026-10-11 14.32.05 2.mov")
        #expect(FileManager.default.fileExists(atPath: first.folder.appendingPathComponent("Screen Recording 2026-10-11 14.32.05.mov").path))
    }

    @Test func aStillTakenFromTheRecordingToolbarIsAScreenshot() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let made = try Self.recorded(png)
        defer { try? FileManager.default.removeItem(at: made.root) }
        let answer = AgentPaneCapture.keepRecording(made.file, taken: Self.taken, in: made.folder)
        #expect(answer["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["data"] as? String == png.base64EncodedString())
        #expect(answer["path"] == nil)
        #expect(!FileManager.default.fileExists(atPath: made.file.path), "the still's temporary file was left behind")
        #expect(!FileManager.default.fileExists(atPath: made.folder.path), "a still made the recordings folder")
    }

    @Test func aRecordingClosedWithoutOneCancels() throws {
        let made = try Self.recorded(Data())
        defer { try? FileManager.default.removeItem(at: made.root) }
        let answer = AgentPaneCapture.keepRecording(made.file, taken: Self.taken, in: made.folder)
        #expect(answer["cancelled"] as? Bool == true)
        #expect(answer["path"] == nil)
    }
}
