package import AppKit
package import CmuxNextWakeups
import Dispatch
import ImageIO
import UniformTypeIdentifiers
import WebKit

// The picture and the state a page keeps from the turn it hides (p13-webui-088,
// plans/cmux-next/chrome-parity/p13-webui.md 3.C). Both are taken when the page hides, never at the
// discard: by then the page may be frozen, and a frozen page cannot answer a call, so a discard that
// asked it for its picture or its state would wait forever and never discard. Chrome's discard asks
// the renderer for nothing either: `WebContents::Discard` keeps the NavigationEntry's PageState and
// the session storage it already has (content/browser/web_contents/web_contents_impl.cc), and the page
// saves what it needs on `visibilitychange`, the last event it is sure to get before a freeze
// (third_party/blink/renderer/core/page/page_visibility_state.h, the Page Lifecycle API).
extension PageWebView {
    /// The `window.webkit.messageHandlers` name a page posts its saved state to when it hides
    /// (webviews/src/pages/shared/pageLifecycle.ts, `PAGE_STATE_HANDLER`).
    static let pageStateHandler = "cmuxPageState"

    /// Keeps the frame the page last showed. The page lifecycle calls it in the turn the page hides,
    /// while the view is still in its window and before any freeze. Chromium copies its surface with no
    /// DevTools agent and encodes it on its thread pool; WebKit hands over its last frame
    /// (`afterScreenUpdates` off: a hidden page draws no new one), kept as it is until a discard
    /// encodes it (``discardDocument(encoder:)``). Makes no call into the page.
    func keepHideSnapshot() {
        let size = snapshotPixelSize
        guard size.width >= 1, size.height >= 1 else { return hideState.drop() }
        let capture = hideState.beginCapture()
        if let session = chromiumSession {
            session.page.copySurface(maxPixelSize: size) { [weak self] copy in
                self?.hideState.captured(capture, copy.map(PageHideState.Picture.encoded) ?? .empty)
            }
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            let frame = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            self?.hideState.captured(capture, frame.map(PageHideState.Picture.frame) ?? .empty)
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

/// What one ``PageWebView`` keeps from its last hide: the picture of its last frame and the state its
/// page saved (``PageWebView/keepHideSnapshot()``). A discard shows the picture until the page draws
/// again and hands the state back to the page (p13-webui-030).
@MainActor
package final class PageHideState {
    /// The picture of the page's last shown frame.
    package enum Picture {
        /// No picture: the page shows, never hid, or its engine gave none.
        case empty
        /// Asked of the engine at the hide, not answered yet.
        case capturing
        /// WebKit's frame as drawn, not encoded: most hidden pages show again before a discard, so
        /// only a discard pays for the encode.
        case frame(CGImage)
        /// Being encoded off the main thread for a discard (``PageSnapshotEncoder``).
        case encoding
        /// Encoded: what a discarded page keeps (Chromium's copy comes encoded).
        case encoded(PageEncodedSnapshot)
    }

    /// One capture or encode; an answer for an older one (the page showed or hid again since) is dropped.
    package struct Generation: Equatable, Sendable {
        fileprivate let value: Int
    }

    /// The most a page may save (64 KiB of UTF-8), as the design's native-held state blob.
    package static let maxStateBytes = 64 * 1024

    package private(set) var picture: Picture = .empty
    /// The state the page posted on its last hide (JSON text); nil when it saved none or more than
    /// ``maxStateBytes``.
    package private(set) var savedState: String?
    private var generation = 0
    /// The encoder of a discard that came while the picture was still on its way.
    private var encodeOnArrival: PageSnapshotEncoder?

    package init() {}

    /// The encoded picture; nil until there is one.
    package var encoded: PageEncodedSnapshot? {
        if case .encoded(let snapshot) = picture { snapshot } else { nil }
    }

    /// Whether the picture is a frame not encoded yet.
    package var keepsFrame: Bool {
        if case .frame = picture { true } else { false }
    }

    /// A new picture is on its way; any older one goes.
    package func beginCapture() -> Generation {
        generation += 1
        encodeOnArrival = nil
        picture = .capturing
        return Generation(value: generation)
    }

    /// The engine answered `capture` with `result` (``Picture/frame(_:)``, ``Picture/encoded(_:)`` or
    /// ``Picture/empty``). A discard that came first encodes it now.
    package func captured(_ capture: Generation, _ result: Picture) {
        guard capture.value == generation, case .capturing = picture else { return }
        picture = result
        guard let encoder = encodeOnArrival else { return }
        encodeOnArrival = nil
        encodeForDiscard(with: encoder)
    }

    /// The page shows again running: the picture is out of date.
    package func drop() {
        generation += 1
        encodeOnArrival = nil
        picture = .empty
    }

    /// The lifecycle discards the page: a frame not encoded yet is encoded by `encoder`, off the main
    /// thread, and the decoded frame goes once that is done. Nothing else to do for an encoded or
    /// missing picture; a picture still on its way is encoded when it comes.
    package func encodeForDiscard(with encoder: PageSnapshotEncoder) {
        switch picture {
        case .frame(let image):
            picture = .encoding
            let encoding = Generation(value: generation)
            encoder.encode(image) { [weak self] snapshot in self?.encodeDidFinish(encoding, snapshot) }
        case .capturing:
            encodeOnArrival = encoder
        case .empty, .encoding, .encoded:
            break
        }
    }

    private func encodeDidFinish(_ encoding: Generation, _ snapshot: PageEncodedSnapshot?) {
        guard encoding.value == generation, case .encoding = picture else { return }
        picture = snapshot.map(Picture.encoded) ?? .empty
    }

    /// Keeps what the page posted as its state: JSON text of at most ``maxStateBytes``. Anything else
    /// clears it, so a page whose state outgrew the limit is never restored to an older one.
    package func saveState(_ body: Any) {
        guard let text = body as? String, text.utf8.count <= Self.maxStateBytes else {
            savedState = nil
            return
        }
        savedState = text
    }
}

/// Encodes a page's hide-time frame when the page lifecycle discards the page, never earlier, and
/// never on the main thread: on the app's `.cpu` lane at ``WorkPriority/bestEffort`` (QoS `.utility`),
/// as Chrome encodes tab thumbnails on its thread pool (chrome/browser/ui/thumbnails/thumbnail_image.cc).
///
/// ```swift
/// let encoder = PageSnapshotEncoder(work: services.work, mainWork: services.mainWork)
/// hideState.encodeForDiscard(with: encoder)
/// ```
package nonisolated struct PageSnapshotEncoder: Sendable {
    /// Gets the encoded picture, or nil when the frame could not be encoded, on the main actor.
    package typealias Done = @MainActor @Sendable (PageEncodedSnapshot?) -> Void

    private let start: @MainActor @Sendable (CGImage, @escaping Done) -> Void

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
            // discarded at quit needs no picture) and its reply, a posted main task, then never runs.
            work.run(.bestEffort, mayBlock: .cpu) { encode(image) }
                .reply(on: mainWork, class: .background, owner: "webui.snapshot.encode") { done($0) }
        }
    }

    /// An encoder that runs `start` (tests).
    package init(start: @escaping @MainActor @Sendable (CGImage, @escaping Done) -> Void) {
        self.start = start
    }

    /// Encodes `image`; `done` gets the result on the main actor.
    @MainActor
    package func encode(_ image: CGImage, done: @escaping Done) {
        start(image, done)
    }

    /// `image` as PNG, alpha kept (a page is transparent over its pane's backdrop). Off the main
    /// thread only: a full window is megabytes of pixels.
    package static func png(_ image: CGImage) -> PageEncodedSnapshot? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PageEncodedSnapshot(data: output as Data, pixelSize: CGSize(width: image.width, height: image.height))
    }
}
