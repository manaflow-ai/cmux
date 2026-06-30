#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import ImageIO
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
/// the left of the field opens the photo picker for image attachments; the
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
    @FocusState private var isFieldFocused: Bool
    /// Photo-picker selection bound to the system `PhotosPicker`. Cleared after
    /// each batch is encoded and staged so re-picking the same image fires again.
    @State private var pickerSelection: [PhotosPickerItem] = []
    /// Drives the photo picker's presentation from the attach button.
    @State private var isPickerPresented = false
    /// Small downsampled thumbnails keyed by attachment id, built ONCE when each
    /// attachment is staged. The chip row renders these instead of decoding the
    /// full multi-MB `Data` from inside the view body on every composer
    /// re-render (e.g. every keystroke).
    @State private var thumbnailCache = AttachmentThumbnailCache()
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
    init(store: CMUXMobileShellStore, terminalID: String, requestHeightRemeasure: @escaping () -> Void) {
        self.store = store
        self.terminalID = terminalID
        self.requestHeightRemeasure = requestHeightRemeasure
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

    /// This terminal's staged image attachments, shown as the chip row above the
    /// field and sent (in order) ahead of the text on submit.
    private var pendingAttachments: [MobilePendingAttachment] {
        store.pendingAttachments(forTerminalID: terminalID)
    }

    /// The Mac decodes the image to a temp file with a 10 MB cap; mirror the
    /// clipboard paste path and keep the bounded encode under ~8 MB. The store
    /// re-enforces this as the authoritative per-image cap; this constant only
    /// bounds the encode loop below it.
    private nonisolated static let maxImageBytes = CMUXMobileShellStore.maxPendingAttachmentImageBytes

    /// Cap how many images one message may carry, mirrored from the store so the
    /// picker's `maxSelectionCount` matches the store's authoritative count cap.
    /// The store enforces it atomically; this is only a pre-filter for picker UX.
    private static let maxAttachmentCount = CMUXMobileShellStore.maxPendingAttachmentCount

    /// Total encoded-bytes budget across this terminal's staged attachments,
    /// mirrored from the store. The store is the authoritative budget (checked
    /// atomically at mutation time); the view pre-filters against it only for
    /// responsiveness so an obviously-over-budget pick skips the encode.
    private static let maxTotalAttachmentBytes = CMUXMobileShellStore.maxPendingAttachmentTotalBytes

    /// Raw-input file-size ceiling for one picked asset, checked on disk BEFORE
    /// any bytes are read. The source is a file-backed import (see
    /// ``ImportedImageFile``), so an enormous ProRAW/DNG/panorama is rejected
    /// without ever being decoded. A compressed HEIC can decode larger than its
    /// file size, so this is a generous multiple of the 8 MB per-image cap rather
    /// than the cap itself; whatever passes is still downsampled by ImageIO.
    private static let maxRawInputBytes = 60 * 1024 * 1024

    /// Max pixel dimension of the cached chip thumbnail. The chip renders at 56pt;
    /// 3x covers Retina without holding the full-resolution image.
    private nonisolated static let thumbnailMaxPixelSize = 168

    /// Max pixel dimension of the SEND payload. ImageIO downsamples the picked
    /// item to fit this longest edge before re-encoding, so a panorama or a
    /// 48-megapixel HEIC never materializes as a full-resolution raster. 2048 px
    /// keeps screenshot text legible for an agent while bounding the bytes well
    /// under the per-image cap.
    private nonisolated static let sendMaxPixelSize = 2048

    var body: some View {
        composerSurface
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
        .onAppear {
            recordComposerEvent(.composerViewAppear)
            // Focus only when an explicit request preceded this mount (an
            // explicit open after a dismissal, or a terminal switch while the
            // user was mid-compose). A default-open presentation arrives with no
            // pending request, so the field shows WITHOUT summoning the keyboard
            // — iMessage's input bar, visible but unfocused until tapped.
            if store.consumePendingComposerFocusRequest(for: terminalID) {
                focusField()
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
            // A terminal switch must stop dictation so the live transcript does not
            // bleed into the incoming terminal's draft. Hard-cancel, not finalize.
            dictation.cancel()
        }
        .onChange(of: isFieldFocused) { _, focused in
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
            // already back but the terminal proxy holds first responder. Driving
            // `@FocusState` here keeps it the single source of truth (the surface
            // never touches the hosted UITextField directly). Consuming the keyed
            // handshake guards the focus: an outgoing composer observing the same
            // token during a terminal switch does not match the request's target,
            // leaves it armed for the incoming mount, and must not focus itself.
            guard store.consumePendingComposerFocusRequest(for: terminalID) else { return }
            focusField()
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
    @MainActor @ViewBuilder
    private var composerSurface: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                composerBar
            }
        } else {
            composerBar
                .background(.bar)
        }
        #else
        composerBar
            .background(.bar)
        #endif
    }

    @MainActor private var composerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // iMessage-style chip row of staged image attachments, ABOVE the
            // field. Shown only when something is staged so the empty composer
            // keeps its compact one-line height (and the host's measurement).
            if !pendingAttachments.isEmpty {
                attachmentChipRow
            }

            HStack(alignment: .bottom, spacing: 8) {
                MobileComposerIconButton(
                    systemImage: "paperclip",
                    foregroundStyle: AnyShapeStyle(TerminalPalette.foreground.opacity(0.7)),
                    size: controlHeight,
                    accessibilityIdentifier: "MobileComposerAttach",
                    accessibilityLabel: L10n.string("mobile.composer.attach", defaultValue: "Attach Photo")
                ) {
                    isPickerPresented = true
                }

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
                    .foregroundStyle(TerminalPalette.foreground)
                    // 6pt container padding + 3pt here keeps the text's 9pt inset
                    // from the round-7 layout, and bottom-aligns the single-line text
                    // with the inline button's circle.
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("MobileComposerField")

                } trailing: {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(canSend ? .white : TerminalPalette.foreground.opacity(0.35))
                            .frame(width: inlineSendDiameter, height: inlineSendDiameter)
                            .background(
                                Circle().fill(
                                    canSend
                                        ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(TerminalPalette.foreground.opacity(0.12))
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityIdentifier("MobileComposerSend")
                    .accessibilityLabel(L10n.string("mobile.composer.send", defaultValue: "Send"))
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
            maxSelectionCount: Self.maxAttachmentCount,
            matching: .images
        )
        .onChange(of: pickerSelection) { _, items in
            guard !items.isEmpty else { return }
            stagePickedItems(items)
        }
    }

    /// Mic button for on-device voice dictation, beside the attach button on the
    /// leading side. Tapping toggles dictation; while listening it shows a filled,
    /// tinted mic. Disabled when the recognizer is unavailable or permission was
    /// denied so the user is never left tapping a dead control.
    @MainActor private var micButton: some View {
        let listening = dictation.state.isListening
        return MobileComposerIconButton(
            systemImage: "mic",
            activeSystemImage: "mic.fill",
            isActive: listening,
            foregroundStyle: listening ? AnyShapeStyle(Color.red) : AnyShapeStyle(TerminalPalette.foreground.opacity(0.7)),
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

    /// Toggle voice dictation. On start the current text is captured as the merge
    /// base and partial transcriptions are written back into `terminalInputText`
    /// (base + transcript) so dictation appends to whatever was already typed.
    private func toggleDictation() {
        dictation.toggle(existingText: store.terminalInputText) { merged in
            store.terminalInputText = merged
        }
    }

    /// Horizontal, removable thumbnail chips for the staged attachments. Each
    /// chip shows the picked image with an x to remove it.
    @MainActor private var attachmentChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { attachment in
                    AttachmentChip(thumbnail: thumbnailCache.image(for: attachment.id)) {
                        store.removePendingAttachment(id: attachment.id, forTerminalID: terminalID)
                        thumbnailCache.remove(attachment.id)
                        requestHeightRemeasure()
                    }
                }
            }
            .padding(.leading, controlHeight + 8)
            .padding(.trailing, 12)
        }
    }

    /// Focus the field one runloop after appearing. Setting `@FocusState` inline
    /// in `onAppear` is unreliable (the field may not be in the window yet);
    /// deferring lets it take first responder from the terminal input proxy
    /// while that keyboard is still up, so the keyboard hands over in place
    /// instead of dropping and re-animating.
    private func focusField() {
        Task { @MainActor in
            isFieldFocused = true
        }
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
            // Drop cached thumbnails for attachments that are no longer staged
            // (the acknowledged ones), keeping any that a failed send left behind.
            thumbnailCache.retain(ids: pendingAttachments.map(\.id))
            // The chip row shrank (or emptied) as part of the send; re-measure so
            // the band tracks the new height.
            requestHeightRemeasure()
        }
    }

    /// Encode each picked photo the same way the clipboard paste path does (PNG,
    /// falling back to JPEG when over the ~8 MB cap) and stage it as a pending
    /// attachment for this terminal, bounded by both a count cap and a total
    /// byte budget so a large batch cannot balloon observable state. A small
    /// thumbnail is downsampled ONCE per attachment and cached by id, so the
    /// chip row never decodes the full `Data` in the view body. Runs off the
    /// picker callback; the selection is cleared so re-picking the same asset
    /// fires again.
    private func stagePickedItems(_ items: [PhotosPickerItem]) {
        // Capture the signed-in session token before any await. If a sign-out
        // lands while a photo is loading/encoding below, the store bumps this
        // token and the guarded add drops the stale result instead of re-staging
        // the previous user's bytes under a (possibly reused) terminal id.
        let sessionGeneration = store.currentSessionGeneration
        // Cancel any still-running batch before starting this one, so two picker
        // opens in quick succession do not run overlapping encode loops that both
        // mutate the store. The store enforces the count/byte caps atomically, so
        // even an un-cancelled overlap could not exceed the cap; cancelling just
        // stops stale encode work from piling up after the user re-picks.
        stagingTask.task?.cancel()
        stagingTask.task = Task { @MainActor in
            for item in items {
                if Task.isCancelled { break }
                // Cheap pre-filter for responsiveness: stop once the store is at
                // the count cap or the budget is already full. The store remains
                // the authoritative cap (checked atomically at add time); this
                // only avoids loading/encoding picks that obviously cannot land.
                let staged = pendingAttachments
                guard staged.count < Self.maxAttachmentCount else { break }
                let stagedBytes = staged.reduce(0) { $0 + $1.data.count }
                guard stagedBytes < Self.maxTotalAttachmentBytes else { break }
                // Load the asset file-backed: PhotosUI copies the imported image to
                // a temp file on disk and hands back only its URL, so the FULL
                // original (a ProRAW/DNG/panorama can be hundreds of MB) is never
                // slurped into memory as `Data` the way `loadTransferable(Data)`
                // would. ImageIO then downsamples straight from the file below.
                guard let imported = try? await item.loadTransferable(type: ImportedImageFile.self) else { continue }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: imported.url)
                    break
                }
                let fileURL = imported.url
                // Always release the temp file, on every exit from this iteration.
                defer { try? FileManager.default.removeItem(at: fileURL) }
                // Reject an absurdly large source BEFORE reading any bytes. A
                // compressed HEIC can decode larger than its file size, so the
                // bound is a generous multiple of the per-image cap, not the cap
                // itself; ImageIO still downsamples whatever passes.
                if let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int,
                   fileSize > Self.maxRawInputBytes {
                    continue
                }
                // Bounded encode + downsample off the main thread, reading the
                // image straight from the temp FILE (CGImageSourceCreateWithURL),
                // so a giant HEIC/panorama is never materialized as a
                // full-resolution raster in memory. This is the expensive part and
                // must not block the composer's keyboard/typing.
                guard let prepared = await Self.prepare(url: fileURL) else { continue }
                if Task.isCancelled { break }
                // The store is the single source of truth for the count/byte caps
                // and the session-generation guard: it re-checks the CURRENT
                // staged set atomically, so even if a prior (cancelled-too-late)
                // batch already appended, this add cannot push past the cap.
                guard let id = store.addPendingAttachment(
                    prepared.data,
                    format: prepared.format,
                    forTerminalID: terminalID,
                    ifSessionGeneration: sessionGeneration
                ) else { continue }
                // The off-main path hands back the downsampled thumbnail as
                // Sendable PNG bytes; build the UIKit image here on the main
                // actor (UIImage is not Sendable and must not cross the task
                // boundary). A nil/undecodable thumbnail just leaves the chip's
                // placeholder.
                if let thumbnailData = prepared.thumbnail, let thumbnail = UIImage(data: thumbnailData) {
                    thumbnailCache.set(thumbnail, for: id)
                }
            }
            pickerSelection = []
            // A new chip grows the band; ask the host to re-measure.
            requestHeightRemeasure()
        }
    }

    /// The off-main result of preparing one picked image: the encoded bytes to
    /// send, their format hint, and the small chip thumbnail as encoded PNG
    /// bytes. Every field is `Sendable` value data so the whole struct can cross
    /// the detached-task boundary; the chip's `UIImage` is built from
    /// ``thumbnail`` on the main actor, never carried across that boundary.
    private struct PreparedAttachment: Sendable {
        var data: Data
        var format: String
        var thumbnail: Data?
    }

    /// Prepare a picked image from its temp file URL for staging, entirely via
    /// ImageIO and entirely off the main thread. The source is read with
    /// `CGImageSourceCreateWithURL`, so the full original is never slurped into
    /// memory. Both the SEND payload and the chip thumbnail are produced by
    /// downsampling that source with `CGImageSourceCreateThumbnailAtIndex` and
    /// re-encoding the (bounded) `CGImage`, so a large HEIC/JPEG/panorama is NEVER
    /// decoded into a full-size raster and never re-encoded to a hundreds-of-MB
    /// PNG just to measure it. The per-image byte cap is enforced on the bounded
    /// result, downscaling further (JPEG, then progressively smaller) if needed.
    /// Returns `nil` when the file is not a decodable image OR when the staging
    /// task was cancelled (a re-pick, a terminal switch, or the view
    /// disappearing). Every returned field is `Sendable` value data (`Data`), so
    /// nothing UIKit-reference crosses back to the main actor. The caller deletes
    /// the temp file.
    ///
    /// STRUCTURED, not detached: this runs the heavy ImageIO inside a child task
    /// group at background priority, so it is a child of the caller's (staging)
    /// task and cancellation PROPAGATES into it. The old `Task.detached` did not
    /// inherit cancellation, so cancelling the staging task left its ImageIO jobs
    /// running and fanning out temp files. `nonisolated` so the synchronous decode
    /// never runs on the main actor. The cancellation check before the heavy
    /// `CGImageSourceCreateWithURL` skips the decode entirely once cancelled.
    private nonisolated static func prepare(url: URL) async -> PreparedAttachment? {
        // Bail before launching the decode if the staging task is already cancelled.
        if Task.isCancelled { return nil }
        return await withTaskGroup(of: PreparedAttachment?.self) { group in
            group.addTask(priority: .background) {
                // Re-check inside the child task: cancellation may have landed
                // between the parent check and this body starting. Skip the
                // expensive CGImageSourceCreateWithURL when cancelled.
                if Task.isCancelled { return nil }
                // Read the image from the file URL: ImageIO maps it lazily and only
                // ever decodes the downsampled thumbnail below, so the full-resolution
                // raster is never materialized in memory.
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                guard let (data, format) = boundedSendPayload(from: source) else { return nil }
                // The send payload is the costly step; if cancellation landed while
                // it ran, drop the result rather than also encoding the thumbnail.
                if Task.isCancelled { return nil }
                return PreparedAttachment(
                    data: data,
                    format: format,
                    thumbnail: downsampledImageData(
                        from: source,
                        maxPixelSize: thumbnailMaxPixelSize,
                        type: "public.png",
                        jpegQuality: nil
                    )
                )
            }
            // Single child: its value is the prepared attachment (or nil). Awaiting
            // the group here keeps the work structured under the staging task.
            return await group.next() ?? nil
        }
    }

    /// Produce the bounded SEND payload for one picked image from its ImageIO
    /// source. Downsamples to ``sendMaxPixelSize`` (longest edge) so the raster is
    /// always small, then encodes under the per-image byte cap:
    /// 1. PNG at the send size if it already fits (keeps screenshots crisp).
    /// 2. JPEG at decreasing quality.
    /// 3. Progressively smaller dimensions as a last resort.
    /// Returns the encoded bytes + a lowercase format hint, or `nil` if the source
    /// is undecodable. The cap is also re-enforced authoritatively in the store.
    private nonisolated static func boundedSendPayload(from source: CGImageSource) -> (data: Data, format: String)? {
        // PNG at the bounded send size: lossless, and for a typical screenshot it
        // lands well under the cap.
        if let png = downsampledImageData(
            from: source,
            maxPixelSize: sendMaxPixelSize,
            type: "public.png",
            jpegQuality: nil
        ), png.count <= maxImageBytes {
            return (png, "png")
        }
        // JPEG at the bounded send size, stepping quality down until it fits.
        for quality in [0.8, 0.6, 0.4] as [CGFloat] {
            if let jpeg = downsampledImageData(
                from: source,
                maxPixelSize: sendMaxPixelSize,
                type: "public.jpeg",
                jpegQuality: quality
            ), jpeg.count <= maxImageBytes {
                return (jpeg, "jpg")
            }
        }
        // Still over the cap (an extreme source): shrink the dimensions as well,
        // at a low-but-readable JPEG quality, until it fits.
        for maxPixel in [1536, 1024, 768] {
            if let jpeg = downsampledImageData(
                from: source,
                maxPixelSize: maxPixel,
                type: "public.jpeg",
                jpegQuality: 0.5
            ), jpeg.count <= maxImageBytes {
                return (jpeg, "jpg")
            }
        }
        // Last resort: return the smallest JPEG we can even if marginally over the
        // bound; the store re-checks the cap and rejects it if truly too large.
        if let jpeg = downsampledImageData(
            from: source,
            maxPixelSize: 768,
            type: "public.jpeg",
            jpegQuality: 0.4
        ) {
            return (jpeg, "jpg")
        }
        return nil
    }

    /// Downsample one image from an ImageIO source to a bounded longest edge and
    /// re-encode it to the given UTType. `CGImageSourceCreateThumbnailAtIndex`
    /// decodes only a reduced-size image (never the full raster), so this is the
    /// bounded primitive both the send payload and the chip thumbnail run through.
    /// Returns `Data` (Sendable) so the result can cross back to the main actor.
    /// Returns `nil` if the source is undecodable or encoding fails.
    /// - Parameters:
    ///   - maxPixelSize: The longest-edge cap, in pixels, for the downsample.
    ///   - type: The destination UTType identifier (`"public.png"`/`"public.jpeg"`).
    ///   - jpegQuality: The JPEG compression quality (0...1); `nil` for PNG.
    private nonisolated static func downsampledImageData(
        from source: CGImageSource,
        maxPixelSize: Int,
        type: String,
        jpegQuality: CGFloat?
    ) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            type as CFString,
            1,
            nil
        ) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let jpegQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}

/// A file-backed `Transferable` for loading a `PhotosPickerItem` as an on-disk
/// file rather than in-memory `Data`. `FileRepresentation` hands PhotosUI a temp
/// destination and copies the imported image there, so loading this type yields a
/// file URL WITHOUT reading the (possibly hundreds-of-MB ProRAW/panorama) image
/// into memory. The composer then size-gates on disk and downsamples straight
/// from the URL via ImageIO, never materializing the full-resolution raster.
///
/// The framework deletes the import staging area, so we copy the file into our
/// own temp location we control and delete after encoding (the composer's
/// `defer` cleanup). `url` is `Sendable`, so the value crosses task boundaries.
struct ImportedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { imported in
            SentTransferredFile(imported.url)
        } importing: { received in
            // Copy out of the framework-owned staging area into our own uniquely
            // named temp file, which the composer deletes after encoding. Keep the
            // source extension so ImageIO can identify the format from the URL.
            let ext = received.file.pathExtension
            let name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-composer-import-" + name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedImageFile(url: destination)
        }
    }
}

/// Holds the in-flight photo-staging `Task` so a new picker batch can cancel the
/// previous one. A reference type so it survives the composer view's frequent
/// value-type re-creation (held as `@State`).
@MainActor
final class StagingTaskBox {
    var task: Task<Void, Never>?
}

/// A side cache of downsampled chip thumbnails keyed by attachment id, built
/// once per attachment at stage time. A reference type so it survives the
/// composer view's frequent value-type re-creation (held as `@State`); reads in
/// the view body are cheap dictionary lookups, never a full-`Data` decode.
@MainActor
final class AttachmentThumbnailCache {
    private var images: [UUID: UIImage] = [:]

    func image(for id: UUID) -> UIImage? { images[id] }

    func set(_ image: UIImage, for id: UUID) { images[id] = image }

    func remove(_ id: UUID) { images[id] = nil }

    /// Drop every cached thumbnail whose attachment is no longer staged.
    func retain(ids: [UUID]) {
        let keep = Set(ids)
        images = images.filter { keep.contains($0.key) }
    }
}

/// A removable thumbnail chip for one staged image attachment. Renders a
/// pre-built, downsampled thumbnail (cached by the composer at stage time) so
/// the view body never decodes the full encoded `Data` on a re-render.
private struct AttachmentChip: View {
    let thumbnail: UIImage?
    let onRemove: () -> Void

    private let side: CGFloat = 56

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnailView
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(TerminalPalette.foreground.opacity(0.15), lineWidth: 1)
                )

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityIdentifier("MobileComposerAttachmentRemove")
            .accessibilityLabel(L10n.string("mobile.composer.attachment.remove", defaultValue: "Remove Attachment"))
        }
    }

    @MainActor @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TerminalPalette.foreground.opacity(0.12))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(TerminalPalette.foreground.opacity(0.5))
                )
        }
    }
}
#endif
