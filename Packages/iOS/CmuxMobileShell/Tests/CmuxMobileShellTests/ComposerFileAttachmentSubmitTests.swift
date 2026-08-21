import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// End-to-end routing tests for staged FILE attachments in the terminal
/// composer: files upload at send time over `mobile.task.attachment.upload`,
/// the returned Mac paths are prepended (shell-quoted) to the sent text, and a
/// failed upload keeps both the staged file and the unsent text for a retry.
@MainActor
@Suite struct ComposerFileAttachmentSubmitTests {
    private static let capabilities: Set<String> = [
        "workspace.task_create.v1",
        MobileShellComposite.taskAttachmentCapability,
    ]

    private static func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func uploadsStagedFileAndPrependsQuotedPathToText() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.capabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingFileAttachment(
            Self.bytes("file-bytes"),
            fileExtension: "pdf",
            displayName: "report.pdf",
            forTerminalID: termA
        )
        store.terminalInputText = "review this"

        let sent = await store.submitComposer()

        #expect(sent)
        let uploads = await router.recordedAttachmentUploads()
        #expect(uploads.count == 1)
        #expect(uploads.first?.fileName == "report.pdf")
        #expect(uploads.first?.last == true)
        let pastes = await router.recordedPastes()
        #expect(pastes.map(\.surfaceID) == [termA])
        #expect(pastes.first?.text == "'/tmp/uploads/report.pdf' review this")
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
        #expect(store.terminalInputText.isEmpty)
    }

    /// A files-only send (empty field) still composes a non-empty message from
    /// the uploaded paths, in stage order.
    @Test func filesOnlySendComposesPathsMessage() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.capabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingFileAttachment(
            Self.bytes("one"),
            fileExtension: "txt",
            displayName: "a.txt",
            forTerminalID: termA
        )
        store.addPendingFileAttachment(
            Self.bytes("two"),
            fileExtension: "bin",
            displayName: "b.bin",
            forTerminalID: termA
        )

        let sent = await store.submitComposer()

        #expect(sent)
        let pastes = await router.recordedPastes()
        #expect(pastes.first?.text == "'/tmp/uploads/a.txt' '/tmp/uploads/b.bin' ")
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
    }

    /// A rejected upload aborts the submit: the staged file AND the composed
    /// text both survive for a retry, and no message reaches the terminal.
    @Test func failedUploadKeepsFileStagedAndTextUnsent() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.capabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))
        await router.setRejectAttachmentUpload(true)

        store.addPendingFileAttachment(
            Self.bytes("file-bytes"),
            fileExtension: "pdf",
            displayName: "report.pdf",
            forTerminalID: termA
        )
        store.terminalInputText = "keep me"

        let sent = await store.submitComposer()

        #expect(!sent)
        #expect(store.pendingAttachments(forTerminalID: termA).count == 1)
        #expect(store.terminalInputText == "keep me")
        let pastes = await router.recordedPastes()
        #expect(pastes.isEmpty)
    }

    /// Images and files share one staged row but ride different transports:
    /// the image goes through terminal.paste_image, the file through the
    /// chunked upload plus a path reference in the text.
    @Test func mixedImageAndFileSendRoutesEachTransport() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.capabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))

        store.addPendingAttachment(
            Self.bytes("img"),
            format: "png",
            forTerminalID: termA
        )
        store.addPendingFileAttachment(
            Self.bytes("file-bytes"),
            fileExtension: "log",
            displayName: "build.log",
            forTerminalID: termA
        )
        store.terminalInputText = "both"

        let sent = await store.submitComposer()

        #expect(sent)
        let images = await router.recordedPasteImages()
        #expect(images.map(\.format) == ["png"])
        let uploads = await router.recordedAttachmentUploads()
        #expect(uploads.map(\.fileName) == ["build.log"])
        let pastes = await router.recordedPastes()
        #expect(pastes.first?.text == "'/tmp/uploads/build.log' both")
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
    }

    /// A failed upload AFTER an acknowledged image keeps only the file staged
    /// (the image was delivered and removed) and never sends the text.
    @Test func uploadFailureAfterImageSendKeepsFileAndText() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.capabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))
        await router.setRejectAttachmentUpload(true)

        store.addPendingAttachment(
            Self.bytes("img"),
            format: "png",
            forTerminalID: termA
        )
        store.addPendingFileAttachment(
            Self.bytes("file-bytes"),
            fileExtension: "log",
            displayName: "build.log",
            forTerminalID: termA
        )
        store.terminalInputText = "kept"

        let sent = await store.submitComposer()

        #expect(!sent)
        let staged = store.pendingAttachments(forTerminalID: termA)
        #expect(staged.count == 1)
        #expect(staged.first?.kind == .file)
        #expect(store.terminalInputText == "kept")
        let pastes = await router.recordedPastes()
        #expect(pastes.isEmpty)
    }
}
