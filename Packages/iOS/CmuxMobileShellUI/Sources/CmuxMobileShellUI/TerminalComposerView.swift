#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxAgentChatUI
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iMessage-style composer hosted in the terminal surface's composer band.
///
/// A growing multi-line text field with the send button INSIDE its rounded
/// container (trailing edge, riding the last line as the field grows — exactly
/// iMessage's circular up-arrow), rendered with Liquid Glass (iOS 26+, with a
/// thin-material fallback). Send delivers the text as a bracketed paste followed
/// by a single Return (via `terminal.paste`), so a multi-line message lands as
/// one submission instead of fragmenting on every interior newline.
///
/// Open by default per terminal (like iMessage's always-present input bar), and
/// presented does NOT mean focused: the field appears with the keyboard down and
/// takes focus only on a user tap or an explicit focus request from the store
/// (an explicit open/reveal, or a terminal switch mid-compose). The button to
/// the left of the field opens the anchored Photos/Files menu; the
/// composer is dismissed from the accessory toolbar's compose toggle.
///
/// The bottom dock (terminal grid / composer band / accessory toolbar / keyboard)
/// is owned entirely by `GhosttySurfaceView` in one coordinate system. This view is
/// hosted in a `UIHostingController` that `GhosttySurfaceRepresentable` installs into
/// the surface's composer band, directly above the always-visible accessory toolbar.
/// The view reports its measured height through ``onHeightChange`` so the surface can
/// reserve exactly that much above the toolbar; a field-grow therefore pushes ONLY the
/// terminal up while the toolbar and keyboard below stay put. There is no
/// `safeAreaInset` and no toolbar handoff — the prior rounds' two-layout-systems fight
/// is gone because there is only one layout system (the surface).
struct TerminalComposerView: View {
    @Bindable var store: CMUXMobileShellStore
    /// The terminal this composer serves. Focus-request consumption is keyed on
    /// it: during a terminal switch the outgoing composer is still mounted and
    /// observes the same token, so only the view whose terminal matches the
    /// request's target may consume it and focus.
    let terminalID: String
    /// Asks the host to re-measure and re-size the surface's composer band. Fired
    /// whenever the field's content changes (the only driver of this view's height);
    /// the host measures the ideal height via `sizeThatFits` and animates the band.
    let requestHeightRemeasure: () -> Void
    /// Routes explicit composer focus through the surface's input-session owner.
    let requestInputFocus: () -> Void
    /// Mirrors user-driven SwiftUI responder changes into that same owner.
    let inputFocusChanged: (Bool) -> Void
    /// PhotosPicker lifecycle facts consumed by the surface input session.
    let photoPickerWillPresent: () -> Void
    let photoPickerDidPresent: () -> Void
    let photoPickerDidDismiss: () -> Void
    @FocusState private var isFieldFocused: Bool
    /// Photo-picker selection bound to the system `PhotosPicker`. Cleared after
    /// each batch is staged so re-picking the same image fires again.
    @State private var pickerSelection: [PhotosPickerItem] = []
    /// Drives the photo picker's presentation from the attach button.
    @State private var isPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var attachmentError: String?
    @State private var isStagingAttachments = false
    /// The in-flight staging task for the current picker batch, if any. A new
    /// picker batch cancels the previous one so stale encode jobs do not pile up
    /// (and keep mutating the store) after the user re-picks or the view's
    /// lifecycle moves on. Held as `@State` so it survives this value type's
    /// frequent re-creation.
    @State private var stagingTask = StagingTaskBox()
    /// On-device voice dictation for the field. Owned here so its lifecycle is
    /// the composer's: it is torn down on send, focus loss, `onDisappear`, and a
    /// terminal switch so the mic never stays hot after the user leaves. An
    /// `@Observable` reference type is held with `@State`; SwiftUI tracks the
    /// `state` it reads (mic button enabled/listening) automatically.
    @State private var dictation = ComposerDictationController()

    init(
        store: CMUXMobileShellStore,
        terminalID: String,
        requestHeightRemeasure: @escaping () -> Void,
        requestInputFocus: @escaping () -> Void,
        inputFocusChanged: @escaping (Bool) -> Void,
        photoPickerWillPresent: @escaping () -> Void,
        photoPickerDidPresent: @escaping () -> Void,
        photoPickerDidDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.terminalID = terminalID
        self.requestHeightRemeasure = requestHeightRemeasure
        self.requestInputFocus = requestInputFocus
        self.inputFocusChanged = inputFocusChanged
        self.photoPickerWillPresent = photoPickerWillPresent
        self.photoPickerDidPresent = photoPickerDidPresent
        self.photoPickerDidDismiss = photoPickerDidDismiss
    }

    /// Single-line height of the round attach button beside the field. It stays
    /// pinned to the bottom edge of the (taller) field via the outer `HStack`'s
    /// `.bottom` alignment.
    private let controlHeight: CGFloat = 40

    /// Diameter of the iMessage-style send button INSIDE the field's rounded
    /// container. With the container's 6pt vertical padding it exactly fills the
    /// 40pt single-line field height (6 + 28 + 6), centering the circle on a
    /// one-line message; the inner `HStack`'s `.bottom` alignment keeps it riding
    /// the last line as the field grows.
    private let inlineSendDiameter: CGFloat = 28

    /// Line range for the growing compose field. Opens at a SINGLE line (`1...`) so it
    /// starts as a compact one-line message box and grows as the user types, up to 14
    /// lines before scrolling. Each added line grows this view's height, which the host
    /// reserves above the toolbar, pushing only the terminal up.
    private let composerLineLimit = 1...14

    /// Minimum height of the compose field, matching the one-line baseline.
    private let composerFieldMinHeight: CGFloat = 40

    /// Whether the field's text alone is empty. Drives only secondary visuals;
    /// the Send affordance keys on ``canSend`` so an images-only message (empty
    /// text, attachments staged) is still sendable.
    private var trimmedIsEmpty: Bool {
        store.terminalInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send is enabled when the text is non-empty OR at least one attachment is
    /// staged for this terminal (iMessage-style images-only send).
    private var canSend: Bool {
        store.composerCanSend(forTerminalID: terminalID)
    }

    private var sendStatus: MobileTerminalSendStatus {
        store.terminalSendStatus(forTerminalID: terminalID)
    }

    private var isSending: Bool {
        sendStatus == .sending
    }

    /// This terminal's staged attachments, shown above the field and sent in
    /// order ahead of the text on submit.
    private var pendingAttachments: [MobilePendingAttachment] {
        store.pendingAttachments(forTerminalID: terminalID)
    }

    /// Cap how many attachments one message may carry, mirrored from the store so the
    /// picker's `maxSelectionCount` matches the store's authoritative count cap.
    /// The store enforces it atomically; this is only a pre-filter for picker UX.
    private static let maxAttachmentCount = CMUXMobileShellStore.maxPendingAttachmentCount

    var body: some View {
        composerSurface
        .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
        // The field is pinned edge-to-edge inside the surface's composer band, so its
        // outer size is locked to the band height and cannot report its own growth.
        // The field's height is driven solely by its content, so ask the host to
        // re-measure (via `sizeThatFits`, which returns the ideal height independent of
        // the current frame) whenever the text changes — the grow as the user types and
        // the shrink when the field is cleared after a send.
        .onChange(of: store.terminalInputText) { _, _ in
            requestHeightRemeasure()
        }
        // The chip row's presence is the OTHER driver of this view's height, and
        // unlike the text it had no content-change remeasure trigger: an image-only
        // send clears the staged attachments without touching `terminalInputText`,
        // so the text trigger above never fires and the band was left reserved tall
        // around the now-empty field. Remeasure whenever the chip row appears or
        // disappears (its height is constant for any non-zero count, so the
        // empty/non-empty edge is the only height-relevant transition); this action
        // runs after SwiftUI commits the change, so the host measures the collapsed
        // (chip-less) layout rather than the stale tall one.
        .onChange(of: pendingAttachments.isEmpty) { _, _ in
            requestHeightRemeasure()
        }
        .onChange(of: sendStatus) { _, _ in
            requestHeightRemeasure()
        }
        .onChange(of: isStagingAttachments) { _, _ in
            requestHeightRemeasure()
        }
        .onAppear {
            recordComposerEvent(.composerViewAppear)
            // Focus only when an explicit request preceded this mount (an
            // explicit open after a dismissal, or a terminal switch while the
            // user was mid-compose). A default-open presentation arrives with no
            // pending request, so the field shows WITHOUT summoning the keyboard
            // — iMessage's input bar, visible but unfocused until tapped.
            if store.consumePendingComposerFocusRequest(for: terminalID) {
                requestInputFocus()
            }
        }
        .onDisappear {
            // COMPOSER: logged independently of `isComposerPresented`. A
            // disappear with no matching `composerPresentedChanged a==0` is a
            // view-recreation bug (the flag stayed true but SwiftUI rebuilt the
            // view), not an intentional dismiss.
            recordComposerEvent(.composerViewDisappear)
            // Cancel any in-flight staging batch when the composer goes away (a
            // terminal switch recreates this view with a new identity, so the
            // outgoing one disappears; a dismissal unmounts it entirely). The
            // batch's ImageIO work is structured under this task, so cancelling it
            // propagates into the decode and stops fanning out temp files for a
            // composer the user has already left. Without this, a switch right
            // after a big pick leaves the encode running unobserved.
            stagingTask.task?.cancel()
            stagingTask.generation = UUID()
            isStagingAttachments = false
            // Never leave the mic hot after the composer leaves the screen; the
            // user navigated away, so hard-cancel (losing the tail is fine).
            dictation.cancel()
        }
        .onChange(of: terminalID) { _, _ in
            // Defense in depth: if SwiftUI ever reuses this view's identity across
            // a terminal switch (rather than recreating it), the `let terminalID`
            // changing must also cancel the prior terminal's in-flight batch so its
            // encode does not stage onto, or burn CPU for, the new terminal.
            stagingTask.task?.cancel()
            stagingTask.generation = UUID()
            isStagingAttachments = false
            // A terminal switch must stop dictation so the live transcript does not
            // bleed into the incoming terminal's draft. Hard-cancel, not finalize.
            dictation.cancel()
        }
        .onChange(of: isFieldFocused) { _, focused in
            inputFocusChanged(focused)
            // Mirror the field's focus into the store so a terminal switch knows
            // whether the user was mid-compose (and should keep the keyboard up
            // on the incoming composer) or merely looking at the default-open
            // field (keyboard stays down).
            store.composerFieldFocusChanged(focused)
            // The field losing focus stops dictation gracefully (the user moved on
            // but keeps the draft, so the last words are finalized into it). Skip
            // this when dictation itself owns the field: locking it (.disabled
            // while listening/stopping) makes SwiftUI resign first responder, and
            // that lock-driven focus loss must NOT stop the dictation it just
            // started. Only a focus loss while the field is NOT locked is the user
            // moving on, and only that should finalize.
            if !focused, !dictation.locksComposerField {
                dictation.stop()
            }
            // COMPOSER: a focus-lost while the flag stayed presented and the
            // view stayed mounted, yet the field reads empty, isolates the
            // residual TextField/@FocusState render-blank case.
            recordComposerEvent(.composerFieldFocusChanged, a: focused ? 1 : 0)
        }
        .onChange(of: store.composerFocusRequest) { _, _ in
            // The surface asked the field to take focus without re-presenting the
            // composer — the reveal-after-hide case, where the chrome and draft are
            // already back but the terminal proxy holds first responder. The keyed
            // token carries intent to the surface input-session owner; `@FocusState`
            // mirrors the resulting UIKit responder fact. Consuming the handshake
            // guards focus: an outgoing composer observing the same
            // token during a terminal switch does not match the request's target,
            // leaves it armed for the incoming mount, and must not focus itself.
            guard store.consumePendingComposerFocusRequest(for: terminalID) else { return }
            requestInputFocus()
        }
        .onChange(of: isFileImporterPresented) { _, presented in
            if presented { photoPickerDidPresent() } else { photoPickerDidDismiss() }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            stagePickedFiles(result)
        }
        .alert(
            L10n.string("mobile.attachment.error.title", defaultValue: "Couldn’t Add Attachment"),
            isPresented: Binding(
                get: { attachmentError != nil },
                set: { if !$0 { attachmentError = nil } }
            )
        ) { Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {} } message: {
            Text(attachmentError ?? "")
        }
    }

    /// Record a composer diagnostic event into the store's structured log (DEBUG
    /// dogfood builds only) so the "Send to agent" feedback pane exports it. A
    /// no-op when no log is wired (release, or a host that does not set it).
    private func recordComposerEvent(_ code: DiagnosticEventCode, a: Int? = nil) {
        #if DEBUG
        store.diagnosticLog?.record(DiagnosticEvent(code, a: a))
        #endif
    }

    /// On iOS 26 the glass controls float in a `GlassEffectContainer` over the
    /// terminal (no opaque bar — that would be glass-on-glass). Earlier OSes get
    /// a `.bar` material backing behind the material controls.
    @ViewBuilder
    private var composerSurface: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                composerBar
            }
        } else {
            composerBar
                .background(.bar)
        }
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // iMessage-style row of staged attachments, ABOVE the
            // field. Shown only when something is staged so the empty composer
            // keeps its compact one-line height (and the host's measurement).
            if !pendingAttachments.isEmpty || isStagingAttachments {
                attachmentChipRow
            }

            if sendStatus == .failed {
                Label(
                    L10n.string(
                        "mobile.terminal.sendFailed",
                        defaultValue: "Couldn’t send. Check the connection and try again."
                    ),
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .padding(.leading, controlHeight + 8)
                .accessibilityIdentifier("MobileComposerSendFailure")
            }

            HStack(alignment: .bottom, spacing: 8) {
                MobileAttachmentPickerButton(
                    style: .circularPlus,
                    isDisabled: isSending || pendingAttachments.count >= Self.maxAttachmentCount,
                    choosePhotos: { presentPhotoPicker() },
                    chooseFiles: {
                        photoPickerWillPresent()
                        isFileImporterPresented = true
                    }
                )
                .accessibilityIdentifier("MobileComposerAttach")

                micButton

                // The field and its send button share ONE rounded glass container,
                // rendered through the same support component as GUI chat. `.bottom`
                // alignment pins the button to the field's last line as it grows.
                MobileComposerFieldContainer(minHeight: composerFieldMinHeight) {
                    TextField(
                        L10n.string("mobile.composer.placeholder", defaultValue: "Message"),
                        text: $store.terminalInputText,
                        axis: .vertical
                    )
                    // Opens at a single line and grows up to 14 lines so a long message has
                    // room. Each added line grows this view, which the host reserves above the
                    // always-visible toolbar; the toolbar and keyboard never move.
                    .lineLimit(composerLineLimit)
                    // Natural-language to an agent, so normal iOS text assistance
                    // is on (autocorrect, sentence-case, spell check). The raw
                    // terminal input field keeps these OFF; only the composer
                    // enables them.
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .focused($isFieldFocused)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            guard !dictation.locksComposerField else { return }
                            requestInputFocus()
                        }
                    )
                    // Lock the field while dictation owns the text (`.listening`
                    // or `.stopping`). Every recognition callback rewrites the
                    // field as base + transcript, so an edit the user made
                    // mid-dictation would be silently discarded by the next
                    // partial/final. Disabling input until dictation settles to
                    // idle makes that edit impossible rather than letting it be
                    // clobbered. The field stays visible showing the live
                    // transcript; the mic toggle and send stay live (send
                    // hard-cancels dictation -> idle, re-enabling the field).
                    .disabled(dictation.locksComposerField)
                    .foregroundStyle(store.activeTerminalTheme.terminalForegroundColor)
                    // 6pt container padding + 3pt here keeps the text's 9pt inset
                    // from the round-7 layout, and bottom-aligns the single-line text
                    // with the inline button's circle.
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("MobileComposerField")

                } trailing: {
                    Button {
                        send()
                    } label: {
                        composerSendButtonLabel
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending || isStagingAttachments || !canSend)
                    .accessibilityIdentifier("MobileComposerSend")
                    .accessibilityLabel(composerSendAccessibilityLabel)
                }
            }
        }
        .padding(.horizontal, 12)
        // Tighter above the field than below (the user reported too much top
        // padding); the band height is still driven by content + this padding,
        // so the host's re-measure stays correct.
        .padding(.top, 2)
        .padding(.bottom, 8)
        .photosPicker(
            isPresented: $isPickerPresented,
            selection: $pickerSelection,
            maxSelectionCount: max(Self.maxAttachmentCount - pendingAttachments.count, 1),
            selectionBehavior: .ordered,
            matching: .images
        )
        .onChange(of: pickerSelection) { _, items in
            guard !items.isEmpty else { return }
            stagePickedItems(items)
        }
        .onChange(of: isPickerPresented) { _, isPresented in
            if isPresented {
                photoPickerDidPresent()
            } else {
                photoPickerDidDismiss()
            }
        }
    }

    @ViewBuilder
    private var composerSendButtonLabel: some View {
        Group {
            if isSending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: composerSendSystemImage)
                    .font(.system(size: 15, weight: .bold))
            }
        }
        .foregroundStyle(composerSendForegroundStyle)
        .frame(width: inlineSendDiameter, height: inlineSendDiameter)
        .background(Circle().fill(composerSendBackgroundStyle))
    }

    private var composerSendSystemImage: String {
        switch sendStatus {
        case .failed:
            return "exclamationmark"
        case .idle, .sending, .sent:
            return "arrow.up"
        }
    }

    private var composerSendForegroundStyle: AnyShapeStyle {
        if isSending || sendStatus == .failed || canSend {
            return AnyShapeStyle(Color.white)
        }
        return AnyShapeStyle(
            store.activeTerminalTheme.terminalForegroundColor.opacity(0.35)
        )
    }

    private var composerSendBackgroundStyle: AnyShapeStyle {
        switch sendStatus {
        case .sending:
            return AnyShapeStyle(Color.accentColor)
        case .failed:
            return AnyShapeStyle(Color.red)
        case .idle, .sent:
            return canSend
                ? AnyShapeStyle(Color.accentColor)
                : AnyShapeStyle(
                    store.activeTerminalTheme.terminalForegroundColor.opacity(0.12)
                )
        }
    }

    private var composerSendAccessibilityLabel: String {
        switch sendStatus {
        case .sending:
            return L10n.string("mobile.terminal.sending", defaultValue: "Sending")
        case .sent:
            return L10n.string("mobile.composer.send", defaultValue: "Send")
        case .failed:
            return L10n.string("mobile.terminal.sendFailed.short", defaultValue: "Send failed")
        case .idle:
            return L10n.string("mobile.composer.send", defaultValue: "Send")
        }
    }

    /// Mic button for on-device voice dictation, beside the attach button on the
    /// leading side. Tapping toggles dictation; while listening it shows a filled,
    /// tinted mic. Disabled when the recognizer is unavailable or permission was
    /// denied so the user is never left tapping a dead control.
    private var micButton: some View {
        let listening = dictation.state.isListening
        return MobileComposerIconButton(
            systemImage: "mic",
            activeSystemImage: "mic.fill",
            isActive: listening,
            foregroundStyle: listening
                ? AnyShapeStyle(Color.red)
                : AnyShapeStyle(store.activeTerminalTheme.terminalChromeForegroundColor.opacity(0.78)),
            size: controlHeight,
            pulsesWhenActive: true,
            isDisabled: !dictation.isAvailable,
            accessibilityIdentifier: "MobileComposerMic",
            accessibilityLabel: listening
                ? L10n.string("mobile.composer.mic.stop", defaultValue: "Stop dictation")
                : L10n.string("mobile.composer.mic.start", defaultValue: "Start dictation")
        ) {
            toggleDictation()
        }
    }

    /// Record the modal boundary before changing the PhotosPicker binding. The
    /// surface input session synchronously resigns its actual terminal/composer
    /// owner; SwiftUI then mirrors that responder change through `@FocusState`.
    private func presentPhotoPicker() {
        photoPickerWillPresent()
        isPickerPresented = true
    }

    /// Toggle voice dictation. On start the current text is captured as the merge
    /// base and partial transcriptions are written back into `terminalInputText`
    /// (base + transcript) so dictation appends to whatever was already typed.
    private func toggleDictation() {
        dictation.toggle(existingText: store.terminalInputText) { merged in
            store.terminalInputText = merged
        }
    }

    /// Horizontal, removable preview cards for staged images and files.
    private var attachmentChipRow: some View {
        MobileAttachmentCardStrip(
            attachments: pendingAttachments.map {
                MobileStagedAttachment(
                    id: $0.id,
                    kind: $0.kind,
                    fileName: $0.fileName,
                    localFileURL: $0.localFileURL,
                    byteCount: $0.byteCount,
                    thumbnailData: $0.thumbnailData
                )
            },
            isDisabled: isSending,
            isPreparing: isStagingAttachments,
            onPreviewDismiss: {
                requestInputFocus()
                isFieldFocused = true
            }
        ) { id in
            store.removePendingAttachment(id: id, forTerminalID: terminalID)
            requestHeightRemeasure()
        }
        .padding(.leading, controlHeight + 8)
        .padding(.trailing, 12)
    }

    private func send() {
        // Allowed with empty text as long as an attachment is staged.
        guard canSend else { return }
        // Hard-cancel dictation before sending, NOT the graceful async stop. Every
        // partial already wrote into `terminalInputText`, so the field holds the
        // latest spoken words at send time. `cancel()` immediately tears down the
        // recognition task and drops `onText`, so (a) `submitComposer()`'s
        // synchronous snapshot of `terminalInputText` captures exactly the current
        // field text, and (b) no late final result can fire `onText` back into the
        // field that send is about to clear. A graceful `stop()` would let a late
        // final result land after the snapshot, dropping the finalized tail from
        // the sent message and re-polluting the just-cleared draft. `cancel()` on
        // an idle controller is a no-op, so a send without active dictation is
        // unchanged.
        dictation.cancel()
        isFieldFocused = true
        Task { @MainActor in
            // Sends staged images first (in order), then the text. Acknowledged
            // attachments are removed from the staged set; a failed send keeps the
            // rest staged for a retry.
            await store.submitComposer()
            // The chip row shrank (or emptied) as part of the send; re-measure so
            // the band tracks the new height.
            requestHeightRemeasure()
        }
    }

    /// Stage each selected photo as an exact-byte, file-backed attachment.
    private func stagePickedItems(_ items: [PhotosPickerItem]) {
        let sessionGeneration = store.currentSessionGeneration
        stagingTask.task?.cancel()
        let stagingGeneration = UUID()
        stagingTask.generation = stagingGeneration
        isStagingAttachments = true
        stagingTask.task = Task { @MainActor in
            defer {
                if stagingTask.generation == stagingGeneration {
                    isStagingAttachments = false
                    stagingTask.task = nil
                }
            }
            for item in items {
                guard !Task.isCancelled,
                      stagingTask.generation == stagingGeneration,
                      sessionGeneration == store.currentSessionGeneration else { break }
                do {
                    guard let imported = try await item.loadTransferable(
                        type: MobileImportedImageFile.self
                    ) else {
                        attachmentError = L10n.string(
                            "mobile.attachment.error.unreadable",
                            defaultValue: "The selected file couldn’t be read."
                        )
                        continue
                    }
                    defer { try? FileManager.default.removeItem(at: imported.url) }
                    let attachment = try await MobileAttachmentStager().stage(
                        sourceURL: imported.url,
                        kind: .image,
                        originalFileName: imported.originalFileName
                    )
                    guard !Task.isCancelled,
                          stagingTask.generation == stagingGeneration,
                          sessionGeneration == store.currentSessionGeneration else {
                        try? FileManager.default.removeItem(at: attachment.localFileURL)
                        continue
                    }
                    admitStagedAttachment(attachment)
                } catch is CancellationError {
                    break
                } catch {
                    attachmentError = attachmentStagingErrorMessage(error)
                }
            }
            pickerSelection = []
            requestHeightRemeasure()
        }
    }

    private func stagePickedFiles(_ result: Result<[URL], any Error>) {
        guard case let .success(urls) = result else {
            if case let .failure(error) = result,
               (error as? CocoaError)?.code == .userCancelled { return }
            attachmentError = L10n.string(
                "mobile.attachment.error.unreadable",
                defaultValue: "The selected file couldn’t be read."
            )
            return
        }
        let sessionGeneration = store.currentSessionGeneration
        stagingTask.task?.cancel()
        let stagingGeneration = UUID()
        stagingTask.generation = stagingGeneration
        isStagingAttachments = true
        stagingTask.task = Task { @MainActor in
            defer {
                if stagingTask.generation == stagingGeneration {
                    isStagingAttachments = false
                    stagingTask.task = nil
                }
            }
            for url in urls {
                guard !Task.isCancelled,
                      stagingTask.generation == stagingGeneration,
                      sessionGeneration == store.currentSessionGeneration else { break }
                do {
                    let attachment = try await MobileAttachmentStager().stage(
                        sourceURL: url,
                        kind: .file,
                        originalFileName: url.lastPathComponent
                    )
                    guard !Task.isCancelled,
                          stagingTask.generation == stagingGeneration,
                          sessionGeneration == store.currentSessionGeneration else {
                        try? FileManager.default.removeItem(at: attachment.localFileURL)
                        continue
                    }
                    admitStagedAttachment(attachment)
                } catch is CancellationError {
                    break
                } catch {
                    attachmentError = attachmentStagingErrorMessage(error)
                }
            }
            requestHeightRemeasure()
        }
    }

    private func attachmentStagingErrorMessage(_ error: any Error) -> String {
        if case MobileAttachmentStager.StagingError.fileTooLarge = error {
            return L10n.string(
                "mobile.taskComposer.attachments.fileTooLarge",
                defaultValue: "Each attachment must be 32 MB or smaller."
            )
        }
        return L10n.string(
            "mobile.taskComposer.attachments.unreadable",
            defaultValue: "The selected file couldn’t be read."
        )
    }

    /// The single Photos/Files handoff into the shell's atomic draft owner.
    private func admitStagedAttachment(_ attachment: MobileStagedAttachment) {
        switch store.admitPendingAttachment(attachment, forTerminalID: terminalID) {
        case .accepted:
            return
        case let .rejected(reason):
            try? FileManager.default.removeItem(at: attachment.localFileURL)
            if let message = attachmentAdmissionErrorMessage(reason) {
                attachmentError = message
            }
        }
    }

    private func attachmentAdmissionErrorMessage(
        _ reason: MobileAttachmentAdmissionRejectionReason
    ) -> String? {
        switch reason {
        case .itemSizeLimit:
            return L10n.string(
                "mobile.attachment.error.itemSize",
                defaultValue: "Each attachment must be 32 MB or smaller."
            )
        case .perTerminalCountLimit:
            return L10n.string(
                "mobile.attachment.error.terminalCount",
                defaultValue: "You can attach up to 10 files to this terminal."
            )
        case .perTerminalTotalBytesLimit:
            return L10n.string(
                "mobile.attachment.error.terminalTotalSize",
                defaultValue: "Attachments in this terminal can use up to 32 MB in total."
            )
        case .globalCapacity:
            return L10n.string(
                "mobile.attachment.error.globalCapacity",
                defaultValue: "Attachment capacity is full. Send or remove an attachment and try again."
            )
        case .missingTerminal:
            return nil
        }
    }

}

/// Holds the in-flight photo-staging `Task` so a new picker batch can cancel the
/// previous one. A reference type so it survives the composer view's frequent
/// value-type re-creation (held as `@State`).
@MainActor
final class StagingTaskBox {
    var task: Task<Void, Never>?
    var generation = UUID()
}

#endif
