public import Foundation

/// The outcome of classifying one resolved context-menu candidate URL: download
/// it now, try the next candidate in the fallback chain, or hand off to the
/// native WebKit menu action.
///
/// This is the typed result the context-menu `@objc` download actions act on at
/// each stage of their fallback chain. The view performs the async WebKit
/// point-resolution hops (`findImageURLAtPoint`, `findLinkURLAtPoint`,
/// `findLinkAtPoint`) and the side effects (trace logging, native fallback
/// dispatch); the pure decision of what each resolved URL means is made by
/// ``BrowserContextMenuDownloadCandidateResolver`` and carried back as one of
/// these cases.
public enum BrowserDownloadCandidateDecision: Sendable, Equatable {
    /// Download `url` now (it is the chosen candidate; chain resolution stops).
    case download(URL)
    /// This candidate is not downloadable; continue the fallback chain to the
    /// next candidate.
    case tryNextCandidate
    /// No candidate in the chain is downloadable; run the native WebKit menu
    /// action with the carried diagnostic `reason`.
    case nativeFallback(reason: String)
}

/// Per-stage classification of one resolved primary image URL, before the nearby
/// link is consulted. Produced by
/// ``BrowserContextMenuDownloadCandidateResolver/classifyPrimaryImageCandidate(_:)``.
///
/// The image download action resolves the image under the cursor first, then the
/// nearby link. This type carries the outcomes of the first stage: an immediate
/// downloadable image, a `data:` image held as a fallback, a weak (CDN /
/// favicon-adjacent) candidate held as a last resort (with the diagnostic reason
/// that classified it weak), the URL rejected for download but in a downloadable
/// scheme (so the legacy rejected-primary log fires), or nothing usable. The view
/// stores the held URLs as accumulators and consults the link stage next.
public enum BrowserContextMenuPrimaryImageClassification: Sendable, Equatable {
    /// The reason a normalized image URL was kept only as a weak last-resort
    /// candidate rather than downloaded directly.
    public enum WeakImageReason: String, Sendable {
        /// The URL looks like an image but is a favicon / low-confidence match.
        case faviconOrLowConfidence = "favicon_or_low_confidence"
        /// The URL is a downloadable, non-favicon src that did not classify as a
        /// likely image (extensionless image CDNs).
        case unclassifiedDirectImageSrc = "unclassified_direct_image_src"
    }

    /// The normalized image URL is directly downloadable; download it now.
    case download(URL)
    /// The URL is a `data:` image; hold it as the `dataImage` fallback and keep
    /// resolving the nearby link.
    case holdDataImage(URL)
    /// The normalized URL is a weak (extensionless-CDN or favicon-adjacent)
    /// image candidate; hold it as the `weakImage` last resort, carrying the
    /// reason it was demoted, and keep resolving the nearby link.
    case holdWeakImage(URL, reason: WeakImageReason)
    /// The normalized URL is in a downloadable scheme but rejected as a primary
    /// image candidate (so the legacy rejected-primary log fires); keep
    /// resolving the nearby link.
    case rejectDownloadableNonImage(URL)
    /// The URL contributes no usable image candidate; keep resolving the nearby
    /// link.
    case none
}

/// Classifies resolved context-menu download candidate URLs against the browser
/// download URL predicates and selects, per fallback-chain stage, which candidate
/// to download, whether to try the next candidate, or whether to fall through to
/// the native WebKit menu action.
///
/// Lifted byte-faithfully out of the app-target `CmuxWebView`'s
/// `contextMenuDownloadImage(_:)` and `contextMenuDownloadLinkedFile(_:)` fallback
/// chains. The view keeps the `@objc` actions, the async WebKit point-resolution
/// hops, the trace/debug logging, and the `runContextMenuFallback` side effect; it
/// forwards each resolved URL into this resolver and acts on the returned typed
/// ``BrowserDownloadCandidateDecision``. Only `URL` and the existing
/// ``BrowserDownloadURLClassifier`` predicates cross the seam.
///
/// A pure value type holding only the `Sendable` classifier, so it is `Sendable`
/// and `nonisolated`: callers construct it with the same classifier instance the
/// view already holds and call the per-stage decision methods. Not a static-only
/// namespace of utilities.
public nonisolated struct BrowserContextMenuDownloadCandidateResolver: Sendable {
    /// The shared URL classifier (scheme / favicon / image / Google-redirect /
    /// MIME predicates), injected so the same instance the view holds is reused.
    private let urlClassifier: BrowserDownloadURLClassifier

    /// Creates a candidate resolver over the shared URL classifier.
    public init(urlClassifier: BrowserDownloadURLClassifier) {
        self.urlClassifier = urlClassifier
    }

    // MARK: - Download Image fallback chain

    /// Classifies the primary image URL resolved under the cursor for the
    /// "Download Image" action.
    ///
    /// Mirrors the first stage of the legacy `contextMenuDownloadImage` body:
    /// `nil` URL or a non-`data`/`http`/`https`/`file` scheme yields `.none`; a
    /// `data:` URL is held as the `dataImage` fallback; an `http`/`https`/`file`
    /// URL is normalized (Google-redirect-unwrapped) then tested as a likely
    /// image (download unless it is a favicon, in which case hold it weak),
    /// otherwise as an extensionless downloadable non-favicon image src (held
    /// weak), otherwise rejected.
    public func classifyPrimaryImageCandidate(
        _ url: URL?
    ) -> BrowserContextMenuPrimaryImageClassification {
        guard let url else { return .none }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "data" {
            return .holdDataImage(url)
        }
        guard scheme == "http" || scheme == "https" || scheme == "file" else {
            return .none
        }
        let normalized = urlClassifier.normalizedLinkedDownloadURL(url)
        if urlClassifier.isLikelyImageURL(normalized) {
            if !urlClassifier.isLikelyFaviconURL(normalized) {
                return .download(normalized)
            }
            return .holdWeakImage(normalized, reason: .faviconOrLowConfidence)
        } else if urlClassifier.isDownloadableScheme(normalized),
                  !urlClassifier.isLikelyFaviconURL(normalized) {
            // Some image CDNs use extensionless URLs; keep as last-resort candidate.
            return .holdWeakImage(normalized, reason: .unclassifiedDirectImageSrc)
        }
        return .rejectDownloadableNonImage(normalized)
    }

    /// Which source the image-link fallback stage selected to download, so the
    /// view can emit the matching legacy trace line (`fallbackToDataURL` /
    /// `fallbackToWeakCandidate`) without re-deriving it from URL equality.
    public enum ImageLinkFallbackSelection: Sendable, Equatable {
        /// Download the normalized nearby-link URL (no special fallback log).
        case link(URL)
        /// Download the held `data:` image (`fallbackToDataURL=1`).
        case dataImage(URL)
        /// Download the held weak image (`fallbackToWeakCandidate=1`).
        case weakImage(URL)
        /// No candidate downloadable; run the native fallback with this reason.
        case nativeFallback(reason: String)
    }

    /// Classifies the nearby link URL resolved for the "Download Image" action,
    /// then selects the final candidate from that link and the held `data:` and
    /// weak image fallbacks, identifying the selected source.
    ///
    /// Mirrors the second stage of the legacy `contextMenuDownloadImage` body: a
    /// normalized link that is a downloadable, likely-image, non-favicon URL is
    /// downloaded; otherwise the held `data:` image, then the held weak image,
    /// are tried; otherwise the native fallback runs with the reason
    /// `fallback_link_not_image` when a link was present or `no_image_or_link_url`
    /// when neither a link nor a usable candidate existed. The selected source is
    /// returned so the view emits the matching trace line.
    public func resolveImageLinkFallback(
        linkURL: URL?,
        heldDataImageURL: URL?,
        heldWeakImageURL: URL?
    ) -> ImageLinkFallbackSelection {
        if let linkURL {
            let normalizedLink = urlClassifier.normalizedLinkedDownloadURL(linkURL)
            if urlClassifier.isDownloadableScheme(normalizedLink),
               urlClassifier.isLikelyImageURL(normalizedLink),
               !urlClassifier.isLikelyFaviconURL(normalizedLink) {
                return .link(normalizedLink)
            }
        }

        if let heldDataImageURL {
            return .dataImage(heldDataImageURL)
        }

        if let heldWeakImageURL {
            return .weakImage(heldWeakImageURL)
        }

        if linkURL != nil {
            return .nativeFallback(reason: "fallback_link_not_image")
        }

        return .nativeFallback(reason: "no_image_or_link_url")
    }

    // MARK: - Download Linked File fallback chain

    /// Classifies the link URL resolved for the "Download Linked File" action.
    ///
    /// Mirrors the first stage of the legacy `contextMenuDownloadLinkedFile`
    /// body: a non-`nil` link whose normalized form is in a download-supported
    /// scheme (`http`/`https`/`file`/`data`) is downloaded; otherwise the chain
    /// continues to the image fallback.
    public func classifyLinkedFileCandidate(
        _ url: URL?
    ) -> BrowserDownloadCandidateDecision {
        if let url {
            let normalized = urlClassifier.normalizedLinkedDownloadURL(url)
            if urlClassifier.isDownloadSupportedScheme(normalized) {
                return .download(normalized)
            }
        }
        return .tryNextCandidate
    }

    /// Classifies the image URL resolved under the cursor as the first fallback
    /// for the "Download Linked File" action.
    ///
    /// Mirrors the second stage of the legacy `contextMenuDownloadLinkedFile`
    /// body: an image in a downloadable scheme is downloaded; a `data:` image is
    /// held as the `dataImage` fallback (carried via `.holdDataImage`); anything
    /// else continues the chain to the nearest-anchor fallback.
    public func classifyLinkedFileImageFallback(
        _ url: URL?
    ) -> BrowserContextMenuPrimaryImageClassification {
        guard let url else { return .none }
        if urlClassifier.isDownloadableScheme(url) {
            return .download(url)
        }
        if urlClassifier.isDataURLScheme(url) {
            return .holdDataImage(url)
        }
        return .none
    }

    /// Which source the linked-file nearest-anchor stage selected to download, so
    /// the view emits the matching legacy trace line (`fallbackToDataURL`) only
    /// when the held `data:` image was chosen, never re-deriving it from URL
    /// equality against a coincidentally-equal anchor.
    public enum LinkedFileNearestAnchorSelection: Sendable, Equatable {
        /// Download the normalized nearest-anchor URL (no special fallback log).
        case anchor(URL)
        /// Download the held `data:` image (`fallbackToDataURL=1`).
        case dataImage(URL)
        /// No candidate downloadable; run the native fallback with this reason.
        case nativeFallback(reason: String)
    }

    /// Classifies the nearest-anchor URL resolved as the final fallback for the
    /// "Download Linked File" action, then selects between it and the held
    /// `data:` image, identifying the selected source.
    ///
    /// Mirrors the final stage of the legacy `contextMenuDownloadLinkedFile`
    /// body: a `nil` anchor or one whose normalized form is not in a
    /// download-supported scheme falls back to the held `data:` image when
    /// present, else runs the native fallback (`no_link_or_image_url` when no
    /// anchor was found, `nearest_anchor_unsupported_scheme` when the anchor's
    /// scheme is unsupported); a supported anchor is downloaded.
    public func resolveLinkedFileNearestAnchorFallback(
        nearestAnchorURL: URL?,
        heldDataImageURL: URL?
    ) -> LinkedFileNearestAnchorSelection {
        guard let nearestAnchorURL else {
            if let heldDataImageURL {
                return .dataImage(heldDataImageURL)
            }
            return .nativeFallback(reason: "no_link_or_image_url")
        }
        let normalized = urlClassifier.normalizedLinkedDownloadURL(nearestAnchorURL)
        guard urlClassifier.isDownloadSupportedScheme(normalized) else {
            if let heldDataImageURL {
                return .dataImage(heldDataImageURL)
            }
            return .nativeFallback(reason: "nearest_anchor_unsupported_scheme")
        }
        return .anchor(normalized)
    }
}
