public import CoreGraphics
public import Foundation

/// A picture of a tab's page that Chromium copied from its surface and encoded (``CEFTab/copySurface(maxPixelSize:done:)``).
public nonisolated struct CEFSurfaceCopy: Sendable, Equatable {
    /// The encoded image (PNG, alpha kept).
    public var data: Data
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

// A tab's picture with no DevTools agent (fork API 38, p13-webui-077 and 078): Chrome copies a tab
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
    /// pictures the shown page. The base64 answer is decoded off the main actor.
    ///
    /// - Parameters:
    ///   - maxPixelSize: The largest picture, in pixels.
    ///   - done: Runs once on the main actor with the picture, or nil when the fork has no surface
    ///     copy, the page drew nothing, or the browser went away.
    public func copySurface(maxPixelSize: CGSize, done: @escaping @MainActor (CEFSurfaceCopy?) -> Void) {
        guard copiesSurface, let browserID, !isClosed, let width = Self.pixelLimit(maxPixelSize.width),
              let height = Self.pixelLimit(maxPixelSize.height) else { return done(nil) }
        let runtime = runtime
        let call = runtime.startSiteCall(browserID) { shim, id in
            shim.tabCopySurface?(browserID, id, width, height, CEFSurfaceCopyFormat.png.rawValue, 0) ?? 0
        }
        // task-owner: one surface copy; ends with Chromium's reply, its refusal or the site-reply deadline
        Task { @MainActor in
            guard let reply = try? await runtime.siteReply(to: call, what: "surface copy") else { return done(nil) }
            done(await Self.surfaceCopy(reply))
        }
    }

    /// A side of the copy's limit in whole pixels; nil when it is below one pixel or not a number.
    nonisolated static func pixelLimit(_ side: CGFloat) -> Int32? {
        guard side >= 1 else { return nil }
        return Int32(clamping: Int(min(side, CGFloat(Int32.max)).rounded(.down)))
    }

    /// The picture of a CMUX_SHIM_REPLY: value = width | height << 32 in pixels (0: none), json = the
    /// image in base64, which can be megabytes.
    @concurrent
    nonisolated static func surfaceCopy(_ reply: CEFSiteReply) async -> CEFSurfaceCopy? {
        let width = reply.value & 0xFFFF_FFFF, height = (reply.value >> 32) & 0xFFFF_FFFF
        guard width > 0, height > 0, let data = Data(base64Encoded: reply.json), !data.isEmpty else { return nil }
        return CEFSurfaceCopy(data: data, pixelSize: CGSize(width: Int(width), height: Int(height)))
    }
}
