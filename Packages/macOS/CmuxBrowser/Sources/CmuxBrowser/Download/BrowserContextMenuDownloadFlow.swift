public import Foundation

/// Owns the multi-stage context-menu "Copy Image", "Download Image", and
/// "Download Linked File" decision-tree sequencing.
///
/// Lifted byte-faithfully out of the app-target `CmuxWebView`'s `@objc`
/// context-menu action methods. Those `@objc` methods stay thin selector targets:
/// they generate the trace id, read the click point, read the pasteboard change
/// count, resolve the native-WebKit fallback action/target from the clicked
/// `NSMenuItem` (`fallbackFromSender`), emit the two app-side click trace lines,
/// then call into this flow. The flow runs the nested async WebKit
/// point-resolution hops, consults the already-extracted
/// ``BrowserContextMenuDownloadCandidateResolver`` for the per-stage decisions,
/// emits the interleaved `cmuxDebugLog` stage trace lines, and dispatches the
/// download / copy / native-fallback side effects. Everything the package cannot
/// reach (WebKit `evaluateJavaScript`, the download/copy network-save operations,
/// AppKit fallback dispatch, the debug-log sink) rides in through the injected
/// ``BrowserContextMenuDownloadFlowSeam``.
///
/// `@MainActor`: every body originates on the main actor in the legacy view (the
/// `@objc` actions are main-thread AppKit selectors) and the seam closures touch
/// AppKit / WebKit main-thread state, so co-locating this state with its main-actor
/// callers turns the former intra-view calls into plain method calls with no new
/// bridges. No `Sendable`: the seam captures the non-`Sendable` owning view.
@MainActor
public final class BrowserContextMenuDownloadFlow {
    /// Classifies resolved context-menu candidate URLs into the typed per-stage
    /// download / try-next / native-fallback decisions, injected so the same
    /// instance the view holds is reused.
    private let candidateResolver: BrowserContextMenuDownloadCandidateResolver

    /// The app-side seam: WebKit/AppKit point-resolution, download/copy operations,
    /// fallback dispatch, and the debug log sink the flow cannot reach from the
    /// package, supplied at construction by the owning view.
    private let seam: BrowserContextMenuDownloadFlowSeam

    /// Creates a context-menu download flow over the candidate resolver and the
    /// app-side seam. Mirrors ``BrowserContextDownloadService``'s
    /// injected-collaborator construction.
    public init(
        candidateResolver: BrowserContextMenuDownloadCandidateResolver,
        seam: BrowserContextMenuDownloadFlowSeam
    ) {
        self.candidateResolver = candidateResolver
        self.seam = seam
    }

    private func debug(_ message: @autoclosure () -> String) {
        seam.log?(message())
    }

    // MARK: - Copy image

    /// Runs the "Copy Image" sequencing: resolve the source URL, fetch the image
    /// payload, write it to the pasteboard guarding against a pasteboard race, and
    /// run the native fallback on any failure. The `@objc` action has already
    /// emitted the two click trace lines, read `expectedPasteboardChangeCount`, and
    /// resolved `fallbackAction`/`fallbackTarget`.
    public func copyImage(
        at point: NSPoint,
        traceID: String,
        expectedPasteboardChangeCount: Int,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        sender: Any?
    ) {
        seam.resolveCopyImageSourceURL(point) { [weak self] sourceURL in
            guard let self else { return }
            guard let sourceURL else {
                self.debug(
                    "browser.ctxcopy.resolve trace=\(traceID) stage=noSourceURL"
                )
                self.seam.inspectElements(point, traceID, "copy")
                self.seam.runFallback(
                    fallbackAction,
                    fallbackTarget,
                    sender,
                    traceID,
                    "no_copy_image_url"
                )
                return
            }

            self.debug(
                "browser.ctxcopy.resolve trace=\(traceID) stage=resolved url=\(sourceURL.absoluteString)"
            )
            self.seam.fetchCopyPayload(sourceURL, traceID) { payload in
                guard let payload else {
                    self.debug(
                        "browser.ctxcopy.resolve trace=\(traceID) stage=noPayload"
                    )
                    self.seam.runFallback(
                        fallbackAction,
                        fallbackTarget,
                        sender,
                        traceID,
                        "copy_image_fetch_failed"
                    )
                    return
                }

                let writeResult = self.seam.writeCopyPayload(
                    payload,
                    expectedPasteboardChangeCount,
                    traceID
                )
                if writeResult.wrote {
                    return
                }
                if !writeResult.shouldFallback {
                    return
                }

                self.seam.runFallback(
                    fallbackAction,
                    fallbackTarget,
                    sender,
                    traceID,
                    "copy_image_write_failed"
                )
            }
        }
    }

    // MARK: - Download image

    /// Runs the "Download Image" sequencing: resolve the image under the cursor,
    /// classify it (download / hold data: / hold weak / reject), then resolve the
    /// nearby link and select the final candidate from the link and the held data:
    /// / weak fallbacks, downloading it or running the native fallback. The `@objc`
    /// action has already emitted the two click trace lines and resolved
    /// `fallbackAction`/`fallbackTarget`.
    public func downloadImage(
        at point: NSPoint,
        traceID: String,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        sender: Any?
    ) {
        seam.findImageURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            self.debug(
                "browser.ctxdl.resolve trace=\(traceID) kind=image imageURL=\(url?.absoluteString ?? "nil")"
            )
            var dataImageURL: URL?
            var weakImageURL: URL?
            switch self.candidateResolver.classifyPrimaryImageCandidate(url) {
            case .download(let normalized):
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedImageURL=\(normalized.absoluteString)"
                )
                self.seam.startDownload(
                    normalized,
                    sender,
                    fallbackAction,
                    fallbackTarget,
                    traceID
                )
                return
            case .holdDataImage(let dataURL):
                dataImageURL = dataURL
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image dataURLDetected length=\(dataURL.absoluteString.count)"
                )
            case .holdWeakImage(let normalized, let reason):
                weakImageURL = normalized
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedImageURL=\(normalized.absoluteString)"
                )
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image weakCandidateURL=\(normalized.absoluteString) reason=\(reason.rawValue)"
                )
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image rejectedPrimaryImageURL=\(normalized.absoluteString)"
                )
            case .rejectDownloadableNonImage(let normalized):
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedImageURL=\(normalized.absoluteString)"
                )
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image rejectedPrimaryImageURL=\(normalized.absoluteString)"
                )
            case .none:
                break
            }

            // Google Images and similar sites often expose blob:/data: image URLs.
            // If image URL is not directly downloadable, fall back to the nearby link URL.
            self.seam.findLinkURLAtPoint(point) { linkURL in
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackLinkURL=\(linkURL?.absoluteString ?? "nil")"
                )
                if let linkURL {
                    let normalizedLink = self.seam.normalizedURL(linkURL)
                    self.debug(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedFallbackLinkURL=\(normalizedLink.absoluteString)"
                    )
                }

                let selection = self.candidateResolver.resolveImageLinkFallback(
                    linkURL: linkURL,
                    heldDataImageURL: dataImageURL,
                    heldWeakImageURL: weakImageURL
                )
                switch selection {
                case .link(let url):
                    self.seam.startDownload(
                        url,
                        sender,
                        fallbackAction,
                        fallbackTarget,
                        traceID
                    )
                case .dataImage(let url):
                    self.debug(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToDataURL=1"
                    )
                    self.seam.startDownload(
                        url,
                        sender,
                        fallbackAction,
                        fallbackTarget,
                        traceID
                    )
                case .weakImage(let url):
                    self.debug(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToWeakCandidate=1"
                    )
                    self.seam.startDownload(
                        url,
                        sender,
                        fallbackAction,
                        fallbackTarget,
                        traceID
                    )
                case .nativeFallback(let reason):
                    self.seam.inspectElements(point, traceID, "image")
                    self.seam.runFallback(
                        fallbackAction,
                        fallbackTarget,
                        sender,
                        traceID,
                        reason
                    )
                }
            }
        }
    }

    // MARK: - Download linked file

    /// Runs the "Download Linked File" sequencing: resolve the link URL (captured
    /// at contextmenu time, hit test as fallback) and download it when supported,
    /// else fall back to the image under the cursor, then to the nearest anchor and
    /// the held data: image, downloading the chosen candidate or running the native
    /// fallback. The `@objc` action has already emitted the two click trace lines
    /// and resolved `fallbackAction`/`fallbackTarget`.
    public func downloadLinkedFile(
        at point: NSPoint,
        traceID: String,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        sender: Any?
    ) {
        // Shared link resolution with the Open Link actions: prefer the link
        // captured at contextmenu time (correct under page zoom and inside
        // iframes), coordinate hit test only as fallback.
        seam.resolveLinkURL(point) { [weak self] url in
            guard let self else { return }
            self.debug(
                "browser.ctxdl.resolve trace=\(traceID) kind=linked linkURL=\(url?.absoluteString ?? "nil")"
            )
            if let url {
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedLinkURL=\(self.seam.normalizedURL(url).absoluteString)"
                )
            }
            switch self.candidateResolver.classifyLinkedFileCandidate(url) {
            case .download(let normalized):
                self.seam.startDownload(
                    normalized,
                    sender,
                    fallbackAction,
                    fallbackTarget,
                    traceID
                )
                return
            case .tryNextCandidate, .nativeFallback:
                break
            }

            // Fallback 1: image URL under cursor (useful on image-heavy result pages).
            self.seam.findImageURLAtPoint(point) { imageURL in
                self.debug(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackImageURL=\(imageURL?.absoluteString ?? "nil")"
                )
                var dataImageURL: URL?
                switch self.candidateResolver.classifyLinkedFileImageFallback(imageURL) {
                case .download(let url):
                    self.seam.startDownload(
                        url,
                        sender,
                        fallbackAction,
                        fallbackTarget,
                        traceID
                    )
                    return
                case .holdDataImage(let dataURL):
                    dataImageURL = dataURL
                    self.debug(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackDataURLDetected length=\(dataURL.absoluteString.count)"
                    )
                case .holdWeakImage, .rejectDownloadableNonImage, .none:
                    break
                }

                // Fallback 2: simpler nearest-anchor lookup.
                self.seam.findLinkAtPoint(point) { fallbackURL in
                    self.debug(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked nearestAnchorURL=\(fallbackURL?.absoluteString ?? "nil")"
                    )
                    if let fallbackURL {
                        self.debug(
                            "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedNearestAnchorURL=\(self.seam.normalizedURL(fallbackURL).absoluteString)"
                        )
                    }
                    let selection = self.candidateResolver.resolveLinkedFileNearestAnchorFallback(
                        nearestAnchorURL: fallbackURL,
                        heldDataImageURL: dataImageURL
                    )
                    switch selection {
                    case .anchor(let url):
                        self.seam.startDownload(
                            url,
                            sender,
                            fallbackAction,
                            fallbackTarget,
                            traceID
                        )
                    case .dataImage(let url):
                        self.debug(
                            "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackToDataURL=1"
                        )
                        self.seam.startDownload(
                            url,
                            sender,
                            fallbackAction,
                            fallbackTarget,
                            traceID
                        )
                    case .nativeFallback(let reason):
                        self.seam.inspectElements(point, traceID, "linked")
                        self.seam.runFallback(
                            fallbackAction,
                            fallbackTarget,
                            sender,
                            traceID,
                            reason
                        )
                    }
                }
            }
        }
    }
}
