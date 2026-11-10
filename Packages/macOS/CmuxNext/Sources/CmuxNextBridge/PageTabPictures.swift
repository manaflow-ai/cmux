import CmuxNextWakeups
public import CoreGraphics

/// Hover-card pictures of page tabs (Markdown, file viewers, diffs, Settings).
///
/// A page tab's card showed only its icon and title (user, 2026-11-09: "hovering on markdown
/// doesnt show me the preview"): the card's thumbnails came only from terminals and browser pages.
/// A page is pictured on a hover, never on a tab switch. The first hover after the page was last
/// on screen takes one picture, kept fitted to ``PreviewImageCache/pagePixelSize`` in a small
/// compressed LRU, and later hovers reuse it until the page shows again
/// (``PagePictureSubject/shownGeneration``). A page on screen is pictured again at most once per
/// ``visibleLifetime`` (a scroll shows), a parked one once per ``hiddenLifetime`` (a file that
/// reloaded while parked shows).
///
/// ```swift
/// let pictures = PageTabPictures()
/// pictures.capture = { _ in fixtureImage }  // a test's camera
/// let image = await pictures.picture(of: pageView, maxPixelSize: CGSize(width: 640, height: 400))
/// ```
@MainActor
public final class PageTabPictures {
    /// The kept pictures, by ``PagePictureSubject/pictureKey``.
    public let cache = PreviewImageCache(capacityBytes: 8 << 20)
    /// Takes a picture of a page; tests inject one. Default: the page's own ``PagePictureSubject/picture()``.
    public var capture: @MainActor (any PagePictureSubject) async -> CGImage? = { await $0.picture() }
    /// The clock the lifetimes and the capture deadline count on; tests inject one.
    public var now: () -> ContinuousClock.Instant = { .now }
    /// How long a picture of a page on screen stands for it.
    public static let visibleLifetime: Duration = .seconds(5)
    /// How long a picture of a parked page stands for it.
    public static let hiddenLifetime: Duration = .seconds(60)
    /// How long one picture may take before the card goes without (a hung page process).
    public static let captureDeadline: Duration = .seconds(2)

    private struct Taken {
        var at: ContinuousClock.Instant
        var generation: Int
    }

    private var taken: [String: Taken] = [:]
    /// One capture per page at a time: a second hover waits for it.
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    /// Makes an empty store.
    public init() {}

    /// `page`'s picture fitted to `maxPixelSize`: the kept one while it still stands for the page,
    /// else a new one.
    ///
    /// - Parameters:
    ///   - page: The page tab's view.
    ///   - maxPixelSize: The card's thumbnail size in pixels.
    /// - Returns: The picture, or the last kept one when a new one fails; nil when the page gives
    ///   none (a native page, a capture past ``captureDeadline``, a flat page with nothing drawn).
    public func picture(of page: any PagePictureSubject, maxPixelSize: CGSize) async -> CGImage? {
        let key = page.pictureKey
        let kept = cache.image(for: key)
        if let kept, isCurrent(key, page: page) { return await PreviewImageCache.decoded(topCrop(kept, to: maxPixelSize), maxPixelSize) }
        let task = inFlight[key] ?? startCapture(of: page)
        guard let image = await task.value ?? kept else { return nil }
        return await PreviewImageCache.decoded(topCrop(image, to: maxPixelSize), maxPixelSize)
    }

    /// The tab closed: its picture goes.
    ///
    /// - Parameter key: The tab's ``PagePictureSubject/pictureKey``.
    public func forget(_ key: String) {
        cache.remove(key)
        taken[key] = nil
        inFlight.removeValue(forKey: key)?.cancel()
    }

    /// Whether `key`'s kept picture still stands for `page`: taken since it last showed, and young enough.
    private func isCurrent(_ key: String, page: any PagePictureSubject) -> Bool {
        guard let taken = taken[key], taken.generation == page.shownGeneration else { return false }
        return now() - taken.at < (page.isOnScreen ? Self.visibleLifetime : Self.hiddenLifetime)
    }

    private func startCapture(of page: any PagePictureSubject) -> Task<CGImage?, Never> {
        let key = page.pictureKey, generation = page.shownGeneration
        // task-owner: inFlight[key]; ends with the picture or its deadline, cancelled when the tab closes
        let task = Task { [weak self, weak page] () -> CGImage? in
            guard let self, let page, let image = await self.captureWithinDeadline(page) else {
                self?.inFlight[key] = nil
                return nil
            }
            let fitted = await PreviewImageCache.fit(image, PreviewImageCache.pagePixelSize)
            // A flat picture (a page that had not drawn) is none, and is not kept: the next hover tries again.
            let blank = await ThumbnailStats.measure(fitted)?.isBlank == true
            guard !Task.isCancelled else { return nil }
            self.inFlight[key] = nil
            guard !blank else { return nil }
            self.cache.insertCompressingLater(fitted, for: key)
            self.taken[key] = Taken(at: self.now(), generation: generation)
            return fitted
        }
        inFlight[key] = task
        return task
    }

    /// ``capture`` of `page`, or nil once ``captureDeadline`` passes: the first of the two resumes the
    /// caller, the other is dropped, so a page process that never answers costs the card its
    /// thumbnail, not a hover that waits forever.
    private func captureWithinDeadline(_ page: any PagePictureSubject) async -> CGImage? {
        let capture = capture
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let answer = OneAnswer(continuation)
            let work = Task { answer.give(await capture(page)) }
            let deadline = DemandTimer(owner: "tabs.pagePicture")
            deadline.schedule(after: Self.captureDeadline) { @MainActor in
                work.cancel()
                answer.give(nil)
            }
            answer.onGiven = { deadline.cancel() }
        }
    }
}

/// `image`'s top, at `size`'s aspect: the card fills its frame centred, which cut a tall page in the middle and lost
/// its heading, the line that names the document. A crop shares the image's pixels (no copy).
private func topCrop(_ image: CGImage, to size: CGSize) -> CGImage {
    guard size.width > 0, size.height > 0 else { return image }
    let height = (CGFloat(image.width) * size.height / size.width).rounded()
    guard height < CGFloat(image.height) else { return image }
    return image.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: height)) ?? image
}

/// Resumes one continuation once, from whichever of a capture and its deadline answers first. Both
/// run on the main actor, so a plain flag decides.
@MainActor
private final class OneAnswer {
    private var continuation: CheckedContinuation<CGImage?, Never>?
    var onGiven: (() -> Void)?

    init(_ continuation: CheckedContinuation<CGImage?, Never>) { self.continuation = continuation }

    func give(_ image: CGImage?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: image)
        onGiven?()
        onGiven = nil
    }
}
