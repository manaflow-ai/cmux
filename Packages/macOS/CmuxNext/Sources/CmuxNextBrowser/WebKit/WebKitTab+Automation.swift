public import CoreGraphics
import WebKit

/// Automation waits and full-page screenshots (`browser.page.wait`,
/// `browser.page.screenshot --full-page`).
extension WebKitTab {
    /// `evaluateJavaScript` does not await a promise; `callAsyncJavaScript`
    /// does. A navigation ends the call with an error.
    public func evaluateAsync(_ body: String) async throws -> BrowserJSValue {
        do {
            return try await callFunction(body, world: .page)
        } catch let error as WKError where error.code == .javaScriptResultTypeIsUnsupported {
            return .null
        } catch let error as WKError where error.code == .javaScriptExceptionOccurred {
            throw BrowserTabError.javaScript(error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
    }

    /// Scrolls the page tile by tile, snapshots each viewport and stitches
    /// them, then scrolls back to where the page was (the old app's
    /// stitched capture). Fixed-position elements repeat in each tile.
    public func fullPageSnapshot() async throws -> CGImage {
        guard !isClosed else { throw BrowserTabError.closed }
        let metrics = try await callFunction(Self.metricsScript, world: .page)
        func number(_ key: String) -> CGFloat { CGFloat(Self.member(metrics, key) ?? 0) }
        // Tiles step by the client area, which leaves out classic scrollbars;
        // each snapshot covers the whole window, scrollbars included.
        guard let plan = BrowserFullPagePlan(contentSize: CGSize(width: number("width"), height: number("height")),
                                             viewportSize: CGSize(width: number("client_width"), height: number("client_height"))) else {
            throw BrowserTabError.unsupported("The page is empty or too large for a full-page screenshot")
        }
        let start = CGPoint(x: number("x"), y: number("y"))
        do {
            let image = try await stitch(plan, windowWidth: max(number("viewport_width"), plan.viewportSize.width))
            _ = try? await scroll(to: start)
            return image
        } catch {
            _ = try? await scroll(to: start)
            throw error
        }
    }

    private func stitch(_ plan: BrowserFullPagePlan, windowWidth: CGFloat) async throws -> CGImage {
        var context: CGContext?
        var scale: CGFloat = 1
        for origin in plan.origins {
            try Task.checkCancellation()
            let actual = try await scroll(to: origin)
            let expected = plan.expectedScroll(for: origin)
            guard abs(actual.x - expected.x) <= 1, abs(actual.y - expected.y) <= 1 else {
                // overflow: hidden, or a scroller other than the document.
                throw BrowserTabError.unsupported("The page did not scroll; a full-page screenshot needs a scrolling document")
            }
            let tile = try await snapshot()
            if context == nil {
                scale = CGFloat(tile.width) / windowWidth
                context = CGContext(data: nil, width: Int((plan.contentSize.width * scale).rounded(.up)),
                                    height: Int((plan.contentSize.height * scale).rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            }
            guard let context else { throw BrowserTabError.snapshotUnavailable }
            // Core Graphics counts y from the bottom.
            let rect = CGRect(x: actual.x * scale, y: CGFloat(context.height) - actual.y * scale - CGFloat(tile.height),
                              width: CGFloat(tile.width), height: CGFloat(tile.height))
            context.draw(tile, in: rect)
        }
        guard let image = context?.makeImage() else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    /// Scrolls to `point` and waits two frames (or 250 ms for a page that
    /// gets no frames) so the snapshot shows it. Returns where it scrolled.
    private func scroll(to point: CGPoint) async throws -> CGPoint {
        let value = try await callFunction(Self.scrollScript, arguments: ["x": .number(Double(point.x)), "y": .number(Double(point.y))],
                                           world: .page)
        return CGPoint(x: Self.member(value, "x") ?? Double(point.x), y: Self.member(value, "y") ?? Double(point.y))
    }

    private static func member(_ value: BrowserJSValue, _ key: String) -> Double? {
        guard case .object(let members) = value else { return nil }
        return members[key]?.numberValue
    }

    private static let metricsScript = """
        const doc = document.documentElement, body = document.body;
        return {
          width: Math.max(doc ? doc.scrollWidth : 0, body ? body.scrollWidth : 0, window.innerWidth || 0),
          height: Math.max(doc ? doc.scrollHeight : 0, body ? body.scrollHeight : 0, window.innerHeight || 0),
          viewport_width: window.innerWidth || 0, viewport_height: window.innerHeight || 0,
          client_width: (doc && doc.clientWidth) || window.innerWidth || 0,
          client_height: (doc && doc.clientHeight) || window.innerHeight || 0,
          x: window.scrollX || 0, y: window.scrollY || 0
        };
        """

    private static let scrollScript = """
        window.scrollTo({ left: x, top: y, behavior: 'instant' });
        await new Promise((resolve) => {
          let done = false;
          const finish = () => { if (!done) { done = true; resolve(); } };
          requestAnimationFrame(() => requestAnimationFrame(finish));
          setTimeout(finish, 250);
        });
        return { x: window.scrollX || 0, y: window.scrollY || 0 };
        """
}
