package import AppKit
import CmuxNextCompat
package import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Dispatch
import UniformTypeIdentifiers
import WebKit

// The picture and the state a page keeps from the turn it hides
// (plans/cmux-next/chrome-parity/p13-webui.md 3.C). Both are taken when the page hides, never at the
// discard: by then the page may be frozen, and a frozen page cannot answer, so a discard that
// asked it for its picture or its state would wait forever and never discard. Chrome's discard asks
// the renderer for nothing either: `WebContents::Discard` keeps the NavigationEntry's PageState and
// the session storage it already has (content/browser/web_contents/web_contents_impl.cc), and the page
// saves what it needs on `visibilitychange`, the last event it is sure to get before a freeze
// (third_party/blink/renderer/core/page/page_visibility_state.h, the Page Lifecycle API).
//
// The picture is encoded as soon as it comes, off the main thread, and only the encoded copy stays, as
// Chrome compresses a tab's captured bitmap on its thread pool and keeps only the compressed one
// (chrome/browser/ui/thumbnails/thumbnail_image.cc). A hidden page that is never discarded (a keep
// reason, `browser.hibernation` off) then holds a PNG, not a decoded window-size bitmap.
extension PageWebView {
    /// The `window.webkit.messageHandlers` name a page posts its saved state to when it hides
    /// (webviews/src/pages/shared/pageLifecycle.ts, `PAGE_STATE_HANDLER`).
    static let pageStateHandler = "cmuxPageState"

    /// Keeps the frame the page last showed. The page lifecycle calls it in the turn the page hides,
    /// before the engine is told the page is hidden (a hidden page draws no frame to picture) and before
    /// any freeze. Chromium copies its surface with no DevTools agent and encodes it on its thread pool;
    /// its answer is base64 text, which `encoder` decodes to the PNG at once off the main thread.
    /// WebKit hands over its last frame (`afterScreenUpdates` off: the page is leaving the screen), which
    /// `encoder` encodes at once off the main thread. Makes no call into the page.
    ///
    /// - Parameter encoder: Encodes a WebKit frame and unpacks a Chromium copy.
    func keepHideSnapshot(encoder: PageSnapshotEncoder) {
        let size = snapshotPixelSize
        // A Chromium page on its way has no engine view and drew nothing.
        guard size.width >= 1, size.height >= 1, !awaitsFirstShow,
              chromiumSession != nil || webKitPieces != nil else { return hideState.drop() }
        let capture = hideState.beginCapture()
        if let session = chromiumSession {
            session.page.copySurface(maxPixelSize: size) { [weak self] copy in
                self?.hideState.captured(capture, copy: copy, encoder: encoder)
            }
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            let frame = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            self?.hideState.captured(capture, frame: frame, encoder: encoder)
        }
    }

    /// The decoded frame of the capture this hide started (WebKit's, as it comes, before its encode), so
    /// another user of the hide's picture (a page tab's discard cover) shares the one engine capture.
    /// Nil at once when no capture is on its way; nil when the capture brings no decoded frame (a
    /// Chromium copy comes encoded) or a show or a newer hide replaces it.
    package func hideFrame() async -> CGImage? {
        try? await withOnceContinuation { (done: OnceContinuation<CGImage?, OnceContinuationError>) in
            if !hideState.whenFrameArrives({ done.resume(returning: $0) }) { done.resume(returning: nil) }
        }
    }

    /// The view's size in pixels of its window's display (2x before it has a window).
    var snapshotPixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    /// Takes what the page posts to ``pageStateHandler`` as its saved state. Install it once, as the
    /// view is made (``addMessageHandler(_:handler:)``).
    func installPageStateSave() {
        addMessageHandler(Self.pageStateHandler) { [weak self] body in self?.hideState.saveState(body) }
    }
}

/// What one ``PageWebView`` keeps from its last hide: the encoded picture of its last frame and the
/// state its page saved (``PageWebView/keepHideSnapshot(encoder:)``). A discard shows the picture until
/// the page draws again and hands the state back to the page.
@MainActor
package final class PageHideState {
    /// The picture of the page's last shown frame. No case holds a decoded frame: a frame goes to its
    /// encode in the turn it comes.
    package enum Picture: Equatable {
        /// No picture: the page shows, never hid, or its engine gave none.
        case empty
        /// Asked of the engine at the hide, not answered yet.
        case capturing
        /// WebKit's frame being encoded, or Chromium's copy being unpacked from base64, off the main
        /// thread (``PageSnapshotEncoder``).
        case encoding
        /// Encoded: what a hidden or discarded page keeps.
        case encoded(PageEncodedSnapshot)
    }

    /// One capture and its encode; an answer for an older one (the page showed or hid again since) is
    /// dropped.
    package struct Generation: Equatable, Sendable {
        fileprivate let value: Int
    }

    /// The most a page may save (64 KiB of UTF-8), as the design's native-held state blob.
    package static let maxStateBytes = 64 * 1024
    /// What the page posts when it keeps no state, none to save or one over ``maxStateBytes``: JSON
    /// `null` (pageLifecycle.ts `writePageState`).
    package static let noStateText = "null"

    package private(set) var picture: Picture = .empty
    /// The state the page posted on its last hide (JSON text); nil when it saved none or more than
    /// ``maxStateBytes``.
    package private(set) var savedState: String?
    private var generation = 0
    /// Who waits for the decoded frame of the capture on its way (``whenFrameArrives(_:)``).
    private var frameWaiters: [@MainActor (CGImage?) -> Void] = []

    package init() {}

    /// The encoded picture; nil until there is one.
    package var encoded: PageEncodedSnapshot? {
        if case .encoded(let snapshot) = picture { snapshot } else { nil }
    }

    /// A new picture is on its way; any older one goes.
    package func beginCapture() -> Generation {
        generation += 1
        picture = .capturing
        answerFrameWaiters(nil)
        return Generation(value: generation)
    }

    /// WebKit answered `capture` with its last frame (nil: none). `encoder` encodes it now, off the
    /// main thread; the state keeps only the encoded picture.
    package func captured(_ capture: Generation, frame: CGImage?, encoder: PageSnapshotEncoder) {
        guard isAwaited(capture) else { return }
        picture = frame == nil ? .empty : .encoding
        answerFrameWaiters(frame)
        guard let frame else { return }
        encoder.encode(frame) { [weak self] snapshot in self?.encodeDidFinish(capture, snapshot) }
    }

    /// Chromium answered `capture` with its surface copy (nil: none). `encoder` unpacks its base64 now, off
    /// the main thread (a full window is megabytes of text); the state keeps only the PNG.
    package func captured(_ capture: Generation, copy: PageSurfaceCopy?, encoder: PageSnapshotEncoder) {
        guard isAwaited(capture) else { return }
        picture = copy == nil ? .empty : .encoding
        answerFrameWaiters(nil)
        guard let copy else { return }
        encoder.unpack(copy) { [weak self] snapshot in self?.encodeDidFinish(capture, snapshot) }
    }

    /// `capture` came back already encoded (nil: none).
    package func captured(_ capture: Generation, encoded: PageEncodedSnapshot?) {
        guard isAwaited(capture) else { return }
        picture = encoded.map(Picture.encoded) ?? .empty
        answerFrameWaiters(nil)
    }

    /// The page shows again running: the picture is out of date.
    package func drop() {
        generation += 1
        picture = .empty
        answerFrameWaiters(nil)
    }

    /// Runs `body` once with the decoded frame of the capture on its way, or with nil when it brings
    /// none or a show or a newer hide replaces it. False, and `body` never runs, when no capture is on
    /// its way.
    package func whenFrameArrives(_ body: @escaping @MainActor (CGImage?) -> Void) -> Bool {
        guard case .capturing = picture else { return false }
        frameWaiters.append(body)
        return true
    }

    /// Keeps what the page posted as its state: JSON text of at most ``maxStateBytes``. Anything else,
    /// and ``noStateText``, clears it, so a page whose state outgrew the limit is never restored to an
    /// older one.
    package func saveState(_ body: Any) {
        guard let text = body as? String, text != Self.noStateText, text.utf8.count <= Self.maxStateBytes else {
            savedState = nil
            return
        }
        savedState = text
    }

    private func isAwaited(_ capture: Generation) -> Bool {
        guard capture.value == generation, case .capturing = picture else { return false }
        return true
    }

    private func encodeDidFinish(_ capture: Generation, _ snapshot: PageEncodedSnapshot?) {
        guard capture.value == generation, case .encoding = picture else { return }
        picture = snapshot.map(Picture.encoded) ?? .empty
    }

    private func answerFrameWaiters(_ frame: CGImage?) {
        guard !frameWaiters.isEmpty else { return }
        let waiters = frameWaiters
        frameWaiters = []
        for waiter in waiters { waiter(frame) }
    }
}

/// Encodes a page's hide-time frame as it comes, and decodes it again when the page is discarded (its
/// show draws the decoded picture in the key's turn), never on the main thread: on the app's `.cpu`
/// lane at ``WorkPriority/bestEffort`` (QoS `.utility`), as Chrome compresses a captured tab bitmap on
/// its thread pool (chrome/browser/ui/thumbnails/thumbnail_image.cc) and decodes images off its UI
/// thread (services/data_decoder/public/cpp/decode_image.h).
///
/// ```swift
/// let encoder = PageSnapshotEncoder(work: services.work, mainWork: services.mainWork)
/// lifecycle.hide(key, page: PageWebViewLifecycle(view, encoder: encoder))
/// ```
package nonisolated struct PageSnapshotEncoder: Sendable {
    /// Gets the encoded picture, or nil when the frame could not be encoded, on the main actor.
    package typealias Done = @MainActor @Sendable (PageEncodedSnapshot?) -> Void

    /// Gets the decoded picture, or nil when it could not be decoded, on the main actor.
    package typealias Decoded = @MainActor @Sendable (CGImage?) -> Void

    private let start: @MainActor @Sendable (CGImage, @escaping Done) -> Void
    private let startDecode: @MainActor @Sendable (PageEncodedSnapshot, @escaping Decoded) -> Void
    private let startUnpack: @MainActor @Sendable (PageSurfaceCopy, @escaping Done) -> Void

    /// The app's encoder.
    ///
    /// - Parameters:
    ///   - work: The app's lanes.
    ///   - mainWork: Where the result comes back, as a posted background-class main task.
    ///   - encode: The encode, run on the lane (tests watch where it runs).
    package init(work: BackgroundWork, mainWork: MainWorkScheduler,
                 encode: @escaping @Sendable (CGImage) -> PageEncodedSnapshot? = { PageSnapshotEncoder.png($0) }) {
        start = { image, done in
            // task-owner: BackgroundWork's `.cpu` lane runs the encode at .bestEffort; quit skips it (a page
            // hidden at quit needs no picture) and its reply, a posted main task, then never runs.
            work.run(.bestEffort, mayBlock: .cpu) { encode(image) }
                .reply(on: mainWork, class: .background, owner: "webui.snapshot.encode") { done($0) }
        }
        startDecode = { snapshot, done in
            // task-owner: BackgroundWork's `.cpu` lane runs the decode at .bestEffort; quit skips it (a
            // discarded page needs no cover at quit) and its reply, a posted main task, then never runs.
            work.run(.bestEffort, mayBlock: .cpu) { blockingImageDecode(snapshot.data) }
                .reply(on: mainWork, class: .background, owner: "webui.snapshot.decode") { done($0) }
        }
        startUnpack = { copy, done in
            // task-owner: BackgroundWork's `.cpu` lane runs the base64 decode at .bestEffort; quit skips it (a page
            // hidden at quit needs no picture) and its reply, a posted main task, then never runs.
            work.run(.bestEffort, mayBlock: .cpu) { copy.encoded() }
                .reply(on: mainWork, class: .background, owner: "webui.snapshot.unpack") { done($0) }
        }
    }

    /// An encoder that runs `start`, `decode` for a discarded page's cover and `unpack` for a Chromium copy
    /// (tests). The default decode gives no picture; the default unpack decodes in the caller's turn.
    package init(start: @escaping @MainActor @Sendable (CGImage, @escaping Done) -> Void,
                 decode: @escaping @MainActor @Sendable (PageEncodedSnapshot, @escaping Decoded) -> Void = { _, done in done(nil) },
                 unpack: @escaping @MainActor @Sendable (PageSurfaceCopy, @escaping Done) -> Void = { copy, done in done(copy.encoded()) }) {
        self.start = start
        startDecode = decode
        startUnpack = unpack
    }

    /// Encodes `image`; `done` gets the result on the main actor.
    @MainActor
    package func encode(_ image: CGImage, done: @escaping Done) {
        start(image, done)
    }

    /// Decodes `snapshot`; `done` gets the picture on the main actor.
    @MainActor
    package func decode(_ snapshot: PageEncodedSnapshot, done: @escaping Decoded) {
        startDecode(snapshot, done)
    }

    /// Unpacks a Chromium surface copy from base64 to its PNG; `done` gets it on the main actor.
    @MainActor
    package func unpack(_ copy: PageSurfaceCopy, done: @escaping Done) {
        startUnpack(copy, done)
    }

    /// `image` as PNG, alpha kept (a page is transparent over its pane's backdrop), encoded in memory
    /// through the CPU seam (no file: CPU work for the `.cpu` lane). Off the main thread only: a full
    /// window is megabytes of pixels.
    package static func png(_ image: CGImage) -> PageEncodedSnapshot? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let data = blockingImageEncode(image, type: UTType.png.identifier as CFString) else { return nil }
        return PageEncodedSnapshot(data: data, pixelSize: CGSize(width: image.width, height: image.height))
    }
}
