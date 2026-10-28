public import CoreGraphics
public import Foundation
import CmuxNextWakeups

/// A picture of a tab's page that Chromium copied from its surface and encoded (``CEFTab/copySurface(maxPixelSize:done:)``).
public nonisolated struct CEFSurfaceCopy: Sendable, Equatable {
    /// The encoded image (PNG, alpha kept) in base64, as the shim's reply carries it. A full window is megabytes of
    /// text: the main actor only passes it on, and the page host decodes it on its `.cpu` lane.
    public var base64: String
    /// Its size in pixels.
    public var pixelSize: CGSize
}

/// `cmux_shim_tab_copy_surface`'s `format`.
nonisolated enum CEFSurfaceCopyFormat: Int32 {
    /// A fast PNG with alpha.
    case png = 0
    /// A JPEG at the call's quality.
    case jpeg = 1
}

// A tab's picture with no DevTools agent (fork API 40): Chrome copies a tab
// thumbnail from its surface (chrome/browser/ui/thumbnails/thumbnail_tab_helper.cc,
// `RenderWidgetHostView::CopyFromSurface`) and encodes it on its thread pool, while a
// `Page.captureScreenshot` attaches a DevTools agent, which ends main-frame renderer reuse for the
// whole browser (`RenderFrameDevToolsAgentHost::WasEverAttachedToAnyFrame`).
extension CEFTab {
    /// Whether ``copySurface(maxPixelSize:done:)`` can give a picture: the fork has the surface copy
    /// (``CEFForkFeatures/surfaceCopy``). False: a picture needs DevTools.
    public var copiesSurface: Bool { runtime.forkFeatures.surfaceCopy }

    /// Copies the page as it last drew, fitted inside `maxPixelSize` (never scaled up), as a PNG with
    /// alpha. The request leaves in the caller's turn, so a copy asked for before the page hides
    /// pictures the shown page.
    ///
    /// - Parameters:
    ///   - maxPixelSize: The largest picture, in pixels.
    ///   - done: Runs once on the main actor with the picture, or nil when the fork has no surface
    ///     copy, the page drew nothing, the browser went away or no answer came in time.
    public func copySurface(maxPixelSize: CGSize, done: @escaping @MainActor (CEFSurfaceCopy?) -> Void) {
        guard copiesSurface, let browserID, !isClosed, let width = CEFSurfaceCopies.pixelLimit(maxPixelSize.width),
              let height = CEFSurfaceCopies.pixelLimit(maxPixelSize.height) else { return done(nil) }
        runtime.surfaceCopies.start(browser: browserID, runtime: runtime, done: done) { shim, reply in
            shim.tabCopySurface?(browserID, reply, width, height, CEFSurfaceCopyFormat.png.rawValue, 0) ?? 0
        }
    }
}

/// The surface copies waiting for Chromium's answer, by reply id (one per runtime, ``CEFRuntime/surfaceCopies``).
/// Every answer comes in a synchronous turn (the shim's CMUX_SHIM_REPLY, the host's REPLY to a refused start, a
/// deadline on ``CEFRuntime/waitDeadlines``, the browser's close): no task waits, as the built-in extension loads.
final class CEFSurfaceCopies {
    /// How long a copy may take: past it the page gets no picture (the fork's own Viz deadline is 2 s).
    static let timeout: Duration = .seconds(5)
    /// The `WakeupLedger` owner of the copies' deadlines.
    static let deadlineOwner = "CEFSurfaceCopies.copy"

    private struct Pending {
        let browser: Int32
        let done: @MainActor (CEFSurfaceCopy?) -> Void
        let deadlines: AlignedWakeups
        let deadline: AlignedWakeups.Ticket
    }

    private var pending: [Int32: Pending] = [:]

    /// Copies waiting now.
    var count: Int { pending.count }

    /// Sends one copy under a fresh reply id (from the site replies' ids, so the two never meet); `send` makes
    /// the shim call. `done` runs once: with the answer, or nil for a refused start, the deadline or the close.
    func start(browser: Int32, runtime: CEFRuntime, done: @escaping @MainActor (CEFSurfaceCopy?) -> Void,
               send: @escaping (CEFShimLibrary, Int32) -> Int32) {
        let id = runtime.nextSiteReply
        runtime.nextSiteReply = id == .max ? 1 : id + 1
        let deadlines = runtime.waitDeadlines
        let deadline = deadlines.schedule(owner: Self.deadlineOwner, after: Self.timeout) { [weak self] in
            self?.finish(id, nil)
        }
        pending[id] = Pending(browser: browser, done: done, deadlines: deadlines, deadline: deadline)
        let sent = runtime.sendAsync { shim in send(shim, id) }
        runtime.whenAnswered(sent, label: "surface copy") { [weak self] started in
            if started != 1 { self?.finish(id, nil) }
        }
    }

    /// A CMUX_SHIM_REPLY: true when it answers one of the copies (value = width | height << 32 in pixels, 0
    /// for none; json = the PNG in base64, passed on undecoded), which then takes no site reply waiter.
    func answer(reply id: Int32, value: Int64, json: String) -> Bool {
        guard pending[id] != nil else { return false }
        finish(id, Self.copy(value: value, base64: json))
        return true
    }

    /// The browser closed: its copies get no picture.
    func browserClosed(_ browser: Int32) {
        for (id, copy) in pending where copy.browser == browser { finish(id, nil) }
    }

    /// The picture of an answer, still in base64 (no decode in the event's turn); nil when it has no size or no image.
    nonisolated static func copy(value: Int64, base64: String) -> CEFSurfaceCopy? {
        let width = value & 0xFFFF_FFFF, height = (value >> 32) & 0xFFFF_FFFF
        guard width > 0, height > 0, !base64.isEmpty else { return nil }
        return CEFSurfaceCopy(base64: base64, pixelSize: CGSize(width: Int(width), height: Int(height)))
    }

    /// A side of the copy's limit in whole pixels; nil below one pixel.
    nonisolated static func pixelLimit(_ side: CGFloat) -> Int32? {
        guard side >= 1 else { return nil }
        return Int32(clamping: Int(min(side, CGFloat(Int32.max)).rounded(.down)))
    }

    /// Ends copy `id` once.
    private func finish(_ id: Int32, _ copy: CEFSurfaceCopy?) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        _ = waiting.deadlines.cancel(waiting.deadline)
        waiting.done(copy)
    }
}
