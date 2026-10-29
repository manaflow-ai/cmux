import AppKit
import CmuxNextCompat
public import CoreGraphics
import IOSurface

/// A hosted page hidden past its grace: one volatile snapshot, no layer host.
///
/// The grace is the app-wide hidden frame list's (``CEFHiddenFrames``, `HiddenFrameLRU`): while it keeps a
/// hidden page's frame, the page keeps its `CALayerHost` and a show is its kept frame. When the list drops
/// it, the fork copies the page's last frame into a new IOSurface on its GPU thread; when the copy is back
/// on the main thread the app marks it volatile, the page drops its `CALayerHost`, puts the snapshot in its
/// place and lets the renderer evict its frame. Volatile pages are outside the process's footprint: under
/// memory pressure the system takes them without asking, and the next show finds the snapshot purged and
/// shows the page's background until Chromium's frame.
///
/// A show (the switch's turn) makes the snapshot non-volatile and puts the layer host back under it, so the
/// switch's commit presents the snapshot; after that commit the fork hears the page shows and its next frame
/// takes the snapshot away. This is Chrome's stale content of an evicted page: `DelegatedFrameHost` copies
/// the surface before it evicts it (`EvictDelegatedFrame`, `DidCopyStaleContent`) and shows the copy in
/// `stale_content_layer_` until the first new surface activates
/// (content/browser/renderer_host/delegated_frame_host.cc).
///
/// Without the fork's copy and next-frame calls (``CEFLayerHosting/Fork``) past the grace is the same with
/// no snapshot: no layer host, the renderer evicted, a show draws the background until the page's frame.
final class CEFHiddenPageSnapshot {
    enum Phase: Equatable {
        /// The page shows its layer host (shown, or hidden within its grace).
        case live
        /// Past its grace: the fork copies the page's last frame.
        case capturing
        /// Past its grace: no layer host, the renderer evicted; ``snapshot`` (volatile) waits for the next show.
        case evicted
        /// Shown again: the snapshot covers the layer host until the page window's next frame.
        case covering
    }

    private(set) var phase = Phase.live
    /// The page's last frame: volatile while ``Phase/evicted``, shown while ``Phase/covering``; nil when
    /// the fork gave none or the system purged it.
    private(set) var snapshot: IOSurface?
    /// The browser whose page the snapshot is: a tab switch while hidden shows another page.
    private(set) var snapshotBrowser: Int32?
    /// Snapshots the fork copied so far.
    private(set) var captures = 0
    /// Snapshots the system purged before they could show or be read.
    private(set) var purged = 0
    /// Bumped by every change of phase, so a late copy or frame of an older one does nothing.
    private var generation: UInt64 = 0
    /// The context the dropped layer host showed, put back at the next show.
    private var droppedContextID: UInt32 = 0
    /// A show of this generation asked the fork for its next frame.
    private var asksFrame = false
    /// Hibernation's reads of the snapshot now: it stays non-volatile while one runs.
    private var readers = 0
    private weak var page: ChromiumHostPageView?

    /// The fork's copy starts: returns its generation.
    func beginCapture(browser: Int32) -> UInt64 {
        generation &+= 1
        phase = .capturing
        snapshotBrowser = browser
        return generation
    }

    /// Whether the copy of `generation` is still wanted (the page did not show or go meanwhile).
    func awaitsCopy(_ generation: UInt64) -> Bool {
        phase == .capturing && generation == self.generation
    }

    /// The copy came back (`snapshot`, already volatile; nil: none). `page` drops its layer host and
    /// holds the snapshot instead, in the hidden view, so a show has nothing to add.
    func evict(page: ChromiumHostPageView, snapshot: IOSurface?) {
        if snapshot != nil { captures += 1 }
        drop(page, keeping: snapshot)
    }

    /// Hidden again past its grace before the page window's next frame: the snapshot it shows (if any) is
    /// still the page's last picture, so it goes volatile again with no new copy. A hibernation read that
    /// runs keeps it non-volatile; its end makes it volatile (``picture(of:)``).
    func evictAgain(page: ChromiumHostPageView) {
        if readers == 0 { snapshot?.makeVolatile() }
        drop(page, keeping: snapshot)
    }

    /// The page shows again, in the switch's turn: the layer host goes back, under the snapshot when it
    /// is this page's and the system kept it, so the switch's commit presents it.
    func show(browser: Int32?) {
        switch phase {
        case .live, .covering:
            return
        case .capturing:
            // Shown before the copy came back: the layer host never left, and the copy goes when it comes.
            release()
        case .evicted:
            generation &+= 1
            if let page, droppedContextID != 0 { _ = page.show(contextID: droppedContextID) }
            guard let snapshot, snapshotBrowser == browser else { return release() }
            guard snapshot.reclaim() else {
                purged += 1
                return release()
            }
            phase = .covering
        }
    }

    /// A tab of the page window shows: a snapshot of another tab's page stops covering it (a hidden
    /// page's snapshot stays; ``show(browser:)`` compares it).
    func pageShown(browser: Int32) {
        guard phase == .covering, snapshotBrowser != browser else { return }
        release()
    }

    /// After the show's commit: the generation to ask the fork's next frame for, once per show.
    func takeFrameRequest() -> UInt64? {
        guard phase == .covering, !asksFrame else { return nil }
        asksFrame = true
        return generation
    }

    /// The page window presented a frame after the show of `generation` (or can present none).
    func frameArrived(generation: UInt64) {
        guard phase == .covering, generation == self.generation else { return }
        release()
    }

    /// The page window went or is not hosted any more: nothing is held for it.
    func reset() {
        release()
    }

    /// The held snapshot of `browser`'s page as a picture, for hibernation: non-volatile while it is
    /// copied off the main thread, volatile again after unless a show took it meanwhile. Nil when the
    /// page holds no snapshot of that page or the system purged it.
    func picture(of browser: Int32) async -> CGImage? {
        guard phase == .evicted, snapshotBrowser == browser, let snapshot else { return nil }
        guard snapshot.reclaim() else {
            // The empty pages go back to volatile, so they never count; the next show draws the background.
            snapshot.makeVolatile()
            purged += 1
            page?.removeSnapshotCover()
            self.snapshot = nil
            return nil
        }
        readers += 1
        let picture = await Self.picture(port: IOSurfaceCreateMachPort(snapshot))
        readers -= 1
        if readers == 0, phase == .evicted, self.snapshot === snapshot { snapshot.makeVolatile() }
        return picture
    }

    private func drop(_ page: ChromiumHostPageView, keeping snapshot: IOSurface?) {
        generation &+= 1
        phase = .evicted
        asksFrame = false
        self.page = page
        self.snapshot = snapshot
        if page.contextID != 0 { droppedContextID = page.contextID }
        // The CALayerHost goes; the context stays the fork's, so the next show hosts it again.
        page.show(contextID: 0)
        if let snapshot { page.coverWithSnapshot(snapshot) } else { page.removeSnapshotCover() }
    }

    private func release() {
        generation &+= 1
        phase = .live
        asksFrame = false
        page?.removeSnapshotCover()
        page = nil
        snapshot = nil
        snapshotBrowser = nil
        droppedContextID = 0
    }

    /// The snapshot's BGRA pixels copied into a picture, off the main thread; nil for another format. The
    /// surface crosses threads as a mach port send right (this function deallocates it), the way Chromium
    /// hands an IOSurface to another thread or process (`gfx::ScopedRefCountedIOSurfaceMachPort`,
    /// ui/gfx/mac/io_surface.h).
    @concurrent nonisolated static func picture(port: mach_port_t) async -> CGImage? {
        guard port != 0 else { return nil }
        let found = IOSurfaceLookupFromMachPort(port)
        _ = mach_port_deallocate(mach_task_self_, port)
        guard let surface = found else { return nil }
        // 'BGRA': the fork copies its frame in the compositor's format.
        guard IOSurfaceGetPixelFormat(surface) == 0x4247_5241, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let (byteCount, overflows) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, bytesPerRow >= width * 4, !overflows, byteCount <= IOSurfaceGetAllocSize(surface) else { return nil }
        // SAFETY: the read-only lock above keeps the base address mapped until the deferred unlock, and the copy
        // reads `byteCount` bytes, which the guard keeps within the surface's allocation.
        let pixels = unsafe Data(bytes: IOSurfaceGetBaseAddress(surface), count: byteCount)
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

extension CEFLayerHosting {
    /// The app-wide list dropped this hidden page's kept frame (``CEFSwitchCommit/pastGrace``): the fork
    /// copies its last frame on its GPU thread, then the layer host goes and the renderer evicts.
    func hiddenPastGrace(browser: Int32, fork: Fork) {
        guard let page else { return switchCommit.evictFrame(browser: browser, fork: fork) }
        switch hiddenSnapshot.phase {
        case .capturing, .evicted:
            return
        case .covering:
            hiddenSnapshot.evictAgain(page: page)
            switchCommit.evictFrame(browser: browser, fork: fork)
        case .live:
            let generation = hiddenSnapshot.beginCapture(browser: browser)
            // A snapshot needs the fork's next frame too: without it nothing could take the snapshot away.
            guard fork.onNextFrame != nil, let copyFrame = fork.copyFrame else {
                return snapshotCopied(nil, generation: generation)
            }
            let started = copyFrame(browser) { [weak self] surface in
                // Volatile from the moment the app holds it: outside the footprint while hidden.
                surface?.makeVolatile()
                self?.snapshotCopied(surface, generation: generation)
            }
            if !started { snapshotCopied(nil, generation: generation) }
        }
    }

    /// The page shows in the switch's turn (``visibilityMayHaveChanged()``).
    func showHiddenSnapshot() {
        hiddenSnapshot.show(browser: browser)
    }

    /// After a commit that leaves the page hidden. A show and a hide in one turn make no fork call, but the
    /// show (``showHiddenSnapshot()``) put the layer host back: a page past its grace drops it again. With
    /// the renderer's frame still evicted that needs no fork call; a copy the show dropped starts again.
    func keepPastGrace(browser: Int32, fork: Fork) {
        guard let page, switchCommit.isPastGrace else { return }
        switch hiddenSnapshot.phase {
        case .capturing, .evicted:
            return
        case .live, .covering:
            if switchCommit.isFrameEvicted {
                hiddenSnapshot.evictAgain(page: page)
            } else {
                hiddenPastGrace(browser: browser, fork: fork)
            }
        }
    }

    /// After the show's commit, the fork heard the page shows: its next frame takes the snapshot away. A
    /// fork that cannot tell gives the live layer at once.
    func awaitFrameUnderSnapshot(browser: Int32, fork: Fork) {
        guard let generation = hiddenSnapshot.takeFrameRequest() else { return }
        let snapshot = hiddenSnapshot
        let asked = fork.onNextFrame?(browser) { [weak snapshot] in snapshot?.frameArrived(generation: generation) } ?? false
        if !asked { snapshot.frameArrived(generation: generation) }
    }

    private func snapshotCopied(_ snapshot: IOSurface?, generation: UInt64) {
        guard hiddenSnapshot.awaitsCopy(generation), let page, let fork, let browser = hiddenSnapshot.snapshotBrowser else { return }
        hiddenSnapshot.evict(page: page, snapshot: snapshot)
        switchCommit.evictFrame(browser: browser, fork: fork)
    }
}

extension CEFTab: BrowserHiddenPagePicture {
    /// The pane's snapshot when this tab's page is the one it holds past its grace.
    public func hiddenPagePicture() async -> CGImage? {
        guard !isClosed, let browserID else { return nil }
        return await host.hostView.layerHosting.hiddenSnapshot.picture(of: browserID)
    }
}
