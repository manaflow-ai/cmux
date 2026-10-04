public import AppKit
public import CmuxHomeCore
import UniformTypeIdentifiers

/// Drop, paste and the file picker all end in `attach`: inputs the allow
/// list refuses get a notice, the rest are prepared by the data side in
/// arrival order and land in the draft tray.
extension HomeNativeTranscriptView {
    /// Files or pictures dropped anywhere on the transcript or the field.
    @discardableResult
    func handleDrop(_ board: any HomePasteboardContents) -> Bool {
        guard attachmentPreparer != nil else { return false }
        let inputs = HomeAttachmentIntake.inputs(from: board)
        guard !inputs.isEmpty else { return false }
        attach(inputs)
        return true
    }

    /// Paste: files and pictures become attachments; text stays text.
    @discardableResult
    func handlePaste(_ board: any HomePasteboardContents) -> Bool {
        handleDrop(board)
    }

    /// The file picker's choice.
    func handlePicked(_ urls: [URL]) {
        guard attachmentPreparer != nil, !urls.isEmpty else { return }
        attach(urls.map { .file($0) })
    }

    /// Opens the file picker as a sheet (the attach button, `home.attachFiles`).
    public func pickFiles() {
        guard let window, attachmentPreparer != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = HomeStrings.attachPrompt
        panel.allowedContentTypes = HomeAttachmentPolicy.allowedTypes.keys.sorted().compactMap { UTType(mimeType: $0) }
        // task-owner: the sheet belongs to the window; the task ends when it closes
        Task { [weak self] in
            guard await panel.beginSheetModal(for: window) == .OK else { return }
            self?.handlePicked(panel.urls)
        }
    }

    /// Prepares `inputs` after every earlier intake, in order.
    func attach(_ inputs: [HomeDraftInput]) {
        guard let preparer = attachmentPreparer else { return }
        var accepted: [HomeDraftInput] = []
        var refusals: [String] = []
        // Attachments plus the text part fit the owner's part limit.
        var room = CmuxHomeCore.HomeAttachmentPolicy.maxParts - 1 - field.draftAttachments.count
        for input in inputs {
            if let refusal = HomeComposerCheck.refusal(for: input) {
                refusals.append(refusal)
            } else if room <= 0 {
                refusals.append(HomeStrings.attachmentRefusal(.tooManyParts(limit: CmuxHomeCore.HomeAttachmentPolicy.maxParts)))
            } else {
                accepted.append(input)
                room -= 1
            }
        }
        field.showNotice(refusals.first)
        guard !accepted.isEmpty else { return }
        let previous = intake
        intake = Task { [weak self] in
            await previous?.value
            for input in accepted {
                let prepared: LocalAttachment
                do {
                    prepared = try await Self.prepare(input, with: preparer)
                } catch let refusal as HomeAttachmentError {
                    self?.field.showNotice(HomeStrings.attachmentRefusal(refusal))
                    continue
                } catch {
                    self?.field.showNotice(HomeStrings.attachFailed)
                    continue
                }
                let thumbnail = await HomeDraftAttachment.thumbnail(for: prepared)
                guard let self, !Task.isCancelled else { return }
                self.field.addDraft(HomeDraftAttachment(prepared: prepared, thumbnail: thumbnail))
            }
        }
    }

    private static func prepare(_ input: HomeDraftInput, with preparer: any HomeAttachmentPreparing) async throws
        -> LocalAttachment {
        switch input {
        case .file(let url): try await preparer.prepareAttachment(fileURL: url, keepLocation: false)
        case .data(let data, let type): try await preparer.prepareAttachment(data: data, typeIdentifier: type, keepLocation: false)
        }
    }

    /// The owner's data side refused a send's attachment before logging it
    /// (`HomeStoreBinding.onAttachmentRefusal`); the draft is back.
    public func showAttachmentRefusal(_ refusal: HomeAttachmentError) {
        field.showNotice(HomeStrings.attachmentRefusal(refusal))
    }

    /// A send the owner refused after it left the composer (a resumed
    /// upload, a resend after backoff): `HomeStoreBinding.onRefusal`.
    public func showRefusal(_ rejection: HomeRejection) {
        field.showNotice(HomeStrings.rejection(rejection))
    }

    /// Returns when every attachment given so far is in the draft (tests).
    func attachmentsReady() async {
        while let current = intake {
            await current.value
            if intake == current { return }
        }
    }

    // MARK: Drag and drop

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Types only: the bytes are read once, on drop.
        guard attachmentPreparer != nil, HomeAttachmentIntake.offers(sender.draggingPasteboard) else { return [] }
        return .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        handleDrop(sender.draggingPasteboard)
    }
}
