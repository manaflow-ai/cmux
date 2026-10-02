import CoreGraphics
import Foundation
import Synchronization

/// The inputs of one background raster job.
nonisolated struct RasterJob: Sendable {
    var key: RasterKey
    var row: TranscriptRow
    var geometry: TranscriptGeometry
    var colors: TranscriptColors
    var scale: CGFloat
    var space: CGColorSpace
}

/// Row bitmaps, drawn ahead on four background threads (MessagesLab
/// `RowRenderer.prefetch`) and kept in a bounded LRU, so a scrolling frame
/// only assigns finished images. A finished drawing wakes the main actor once
/// while placeholders are on screen.
nonisolated final class RowRasterizer: Sendable {
    static let capacity = 360

    private struct State {
        var images: [RasterKey: CGImage] = [:]
        var order: [RasterKey] = []
        var head = 0
        var inFlight: Set<RasterKey> = []
        var placeholdersShown = false
        var wakePosted = false
        var drawnOnMain = 0
        var drawnInBackground = 0
    }

    private let state = Mutex(State())
    private let queue: OperationQueue
    private let onReady: @Sendable () -> Void

    /// `onReady` runs on the main actor after background drawing finished while placeholders show.
    init(onReady: @escaping @MainActor @Sendable () -> Void) {
        let queue = OperationQueue()
        queue.name = "CmuxNextHome.raster"
        queue.qualityOfService = .userInitiated
        // bounded threads, no GCD thread explosion
        queue.maxConcurrentOperationCount = 4
        self.queue = queue
        self.onReady = { Task { @MainActor in onReady() } }
    }

    deinit { queue.cancelAllOperations() }

    func image(_ key: RasterKey) -> CGImage? { state.withLock { $0.images[key] } }

    var counts: (main: Int, background: Int, cached: Int) {
        state.withLock { ($0.drawnOnMain, $0.drawnInBackground, $0.images.count) }
    }

    /// Draws `job` now (a row came on screen without a prefetched drawing).
    func drawNow(_ job: RasterJob) -> CGImage? {
        guard let image = RowPainter.image(job.row, geometry: job.geometry, colors: job.colors, scale: job.scale,
                                           space: job.space) else { return nil }
        store(image, for: job.key, onMain: true)
        return image
    }

    /// Queues every job that has no image and none in flight.
    func prefetch(_ jobs: [RasterJob]) {
        let todo: [RasterJob] = state.withLock { s in
            var out: [RasterJob] = []
            for job in jobs where s.images[job.key] == nil && !s.inFlight.contains(job.key) {
                s.inFlight.insert(job.key)
                out.append(job)
            }
            return out
        }
        for job in todo {
            queue.addOperation { [weak self] in
                autoreleasepool {
                    let image = RowPainter.image(job.row, geometry: job.geometry, colors: job.colors, scale: job.scale,
                                                 space: job.space)
                    guard let self else { return }
                    if let image { self.store(image, for: job.key, onMain: false) }
                    self.finished(job.key)
                }
            }
        }
    }

    /// The view reports after each frame whether a placeholder is still on screen.
    func placeholdersOnScreen(_ any: Bool) { state.withLock { $0.placeholdersShown = any } }

    /// Theme or scale changed: every bitmap is stale.
    func removeAll() {
        queue.cancelAllOperations()
        state.withLock { s in
            s.images.removeAll()
            s.order.removeAll()
            s.head = 0
            s.inFlight.removeAll()
        }
    }

    private func finished(_ key: RasterKey) {
        let post: Bool = state.withLock { s in
            s.inFlight.remove(key)
            guard s.placeholdersShown, !s.wakePosted else { return false }
            s.wakePosted = true
            return true
        }
        guard post else { return }
        onReady()
    }

    /// The main actor consumed a wake.
    func wakeHandled() { state.withLock { $0.wakePosted = false } }

    private func store(_ image: CGImage, for key: RasterKey, onMain: Bool) {
        state.withLock { s in
            if s.images.updateValue(image, forKey: key) == nil { s.order.append(key) }
            if onMain { s.drawnOnMain += 1 } else { s.drawnInBackground += 1 }
            while s.order.count - s.head > Self.capacity {
                s.images[s.order[s.head]] = nil
                s.head += 1
            }
            if s.head > Self.capacity {
                s.order.removeFirst(s.head)
                s.head = 0
            }
        }
    }
}
