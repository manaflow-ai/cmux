@testable import CmuxNextAgentPane
import Foundation
import Testing

/// What `composer.capture` answers the page for what `screencapture` wrote: a capture named for
/// when it was taken (so two in one prompt differ), nothing for a cancelled pick, and a capture too
/// large to attach by name, for the composer's note.
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

    @Test func aCaptureTooLargeToAttachIsNamedForTheNote() {
        // Bytes over the cap that are no image: nothing can scale them under it.
        let answer = AgentPaneCapture.answer(Data(count: AgentPaneCapture.maxBytes + 1), taken: Self.taken)
        #expect(answer["tooLarge"] as? Bool == true)
        #expect(answer["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["data"] == nil)
    }
}
