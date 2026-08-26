import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// End-to-end tests over the real RPC wire (a scripted recording host) for the
/// composer's FILE attachment sends: staged files upload through the chunked
/// task-attachment verb at submit time, their returned Mac paths land in the
/// message shell-quoted ahead of the user's text, chips are removed only after
/// the text send acks, and any failure keeps everything staged for a retry.
@MainActor
@Suite struct ComposerFileAttachmentSubmitTests {
    private static let fileCapabilities: Set<String> = [
        "workspace.task_create.v1",
        "task.attachments.v1",
    ]

    private static func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func uploadsStagedFileAndPrependsQuotedPathToText() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.fileCapabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))
        store.addPendingFileAttachment(
            Self.bytes("pdf-bytes"),
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
        #expect(uploads.first?.totalBytes == Self.bytes("pdf-bytes").count)
        let pastes = await router.recordedPastes()
        #expect(pastes.map(\.text) == ["'/tmp/uploads/report.pdf' review this"])
        #expect(pastes.map(\.surfaceID) == [termA])
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
        #expect(store.terminalInputText.isEmpty)
    }

    @Test func filesOnlySendComposesPathsMessage() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.fileCapabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))
        store.addPendingFileAttachment(
            Self.bytes("aaa"),
            fileExtension: "txt",
            displayName: "a.txt",
            forTerminalID: termA
        )
        store.addPendingFileAttachment(
            Self.bytes("bbb"),
            fileExtension: "bin",
            displayName: "b.bin",
            forTerminalID: termA
        )

        let sent = await store.submitComposer()

        #expect(sent)
        let pastes = await router.recordedPastes()
        #expect(pastes.map(\.text) == ["'/tmp/uploads/a.txt' '/tmp/uploads/b.bin' "])
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
    }

    @Test func failedUploadKeepsFileStagedAndTextUnsent() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.fileCapabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))
        store.addPendingFileAttachment(
            Self.bytes("keep me"),
            fileExtension: "txt",
            displayName: "keep.txt",
            forTerminalID: termA
        )
        store.terminalInputText = "still mine"

        await router.setRejectAttachmentUpload(true)
        let sent = await store.submitComposer()

        #expect(!sent)
        #expect(store.pendingAttachments(forTerminalID: termA).count == 1)
        #expect(store.terminalInputText == "still mine")
        let pastes = await router.recordedPastes()
        #expect(pastes.isEmpty)
        #expect(store.terminalSendStatus(forTerminalID: termA) == .failed)
    }

    @Test func mixedImageAndFileSendRoutesEachTransport() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.fileCapabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))
        store.addPendingAttachment(
            Self.bytes("image"),
            format: "png",
            forTerminalID: termA
        )
        store.addPendingFileAttachment(
            Self.bytes("notes"),
            fileExtension: "md",
            displayName: "notes.md",
            forTerminalID: termA
        )
        store.terminalInputText = "both attached"

        let sent = await store.submitComposer()

        #expect(sent)
        let images = await router.recordedPasteImages()
        #expect(images.map(\.format) == ["png"])
        let uploads = await router.recordedAttachmentUploads()
        #expect(uploads.map(\.fileName) == ["notes.md"])
        let pastes = await router.recordedPastes()
        #expect(pastes.map(\.text) == ["'/tmp/uploads/notes.md' both attached"])
        #expect(store.pendingAttachments(forTerminalID: termA).isEmpty)
    }

    @Test func missingHostCapabilityFailsFileSendAndKeepsChip() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: ["workspace.task_create.v1"]
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))
        store.addPendingFileAttachment(
            Self.bytes("blocked"),
            fileExtension: "txt",
            displayName: "blocked.txt",
            forTerminalID: termA
        )
        store.terminalInputText = "cannot go"

        let sent = await store.submitComposer()

        #expect(!sent)
        #expect(store.pendingAttachments(forTerminalID: termA).count == 1)
        #expect(store.terminalInputText == "cannot go")
        let uploads = await router.recordedAttachmentUploads()
        #expect(uploads.isEmpty)
        let pastes = await router.recordedPastes()
        #expect(pastes.isEmpty)
    }

    @Test func quotedPathEscapesApostrophesInFileName() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: Self.fileCapabilities
        )
        let termA = RoutingHostRouter.terminalA
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: termA))
        store.addPendingFileAttachment(
            Self.bytes("quoted"),
            fileExtension: "pdf",
            displayName: "Customer's report.pdf",
            forTerminalID: termA
        )

        let sent = await store.submitComposer()

        #expect(sent)
        let pastes = await router.recordedPastes()
        #expect(pastes.map(\.text) == [
            "'/tmp/uploads/Customer'\\''s report.pdf' ",
        ])
    }
}
