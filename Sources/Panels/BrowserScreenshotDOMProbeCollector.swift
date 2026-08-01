import AppKit
import CmuxBrowser
import QuartzCore
import WebKit

/// Reads stable, high-contrast text probes from one `WKWebView`.
@MainActor
final class BrowserScreenshotDOMProbeCollector {
    private weak var webView: WKWebView?
    private let animationFrameTimeout: TimeInterval
    private let synchronizationJavaScriptTimeout: TimeInterval
    private let javaScriptTimeout: TimeInterval

    init(
        webView: WKWebView,
        animationFrameTimeout: TimeInterval = 1,
        synchronizationJavaScriptTimeout: TimeInterval = 1,
        javaScriptTimeout: TimeInterval = 1
    ) {
        self.webView = webView
        self.animationFrameTimeout = animationFrameTimeout
        self.synchronizationJavaScriptTimeout = synchronizationJavaScriptTimeout
        self.javaScriptTimeout = javaScriptTimeout
    }

    func synchronize(
        waitForAnimationFrame: Bool
    ) async throws -> BrowserScreenshotSynchronizationOutcome {
        guard let webView else { return .unconfirmed }
        forceAppKitLayout(for: webView)

        do {
            if waitForAnimationFrame {
                try await waitForAnimationFrames(in: webView)
            } else {
                _ = try await evaluate(
                    layoutFlushScript,
                    in: webView,
                    timeout: synchronizationJavaScriptTimeout
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
#if DEBUG
            cmuxDebugLog(
                "browser.screenshot.synchronize.unconfirmed error=\(error.localizedDescription)"
            )
#endif
            forceAppKitLayout(for: webView)
            return .unconfirmed
        }

        forceAppKitLayout(for: webView)
        return .completed
    }

    func collect() async -> BrowserScreenshotProbeSet? {
        guard let webView else { return nil }
        do {
            guard let value = try await evaluate(
                probeScript,
                in: webView,
                timeout: javaScriptTimeout
            )
                as? [String: Any] else {
                return nil
            }
            return probeSet(from: value)
        } catch {
#if DEBUG
            cmuxDebugLog("browser.screenshot.probes.failed error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    private func probeSet(
        from value: [String: Any]
    ) -> BrowserScreenshotProbeSet? {
        let viewportSize = NSSize(
            width: number(value["viewportWidth"]),
            height: number(value["viewportHeight"])
        )
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0,
              let values = value["probes"] as? [[String: Any]] else {
            return nil
        }

        let probes = values.compactMap { probeValue -> BrowserScreenshotProbe? in
            guard let identifier = probeValue["identifier"] as? String,
                  let text = probeValue["text"] as? String,
                  let rectValue = probeValue["rect"] as? [String: Any],
                  let foregroundValue = probeValue["foreground"] as? [String: Any],
                  let backgroundValue = probeValue["background"] as? [String: Any],
                  let foreground = color(from: foregroundValue),
                  let background = color(from: backgroundValue) else {
                return nil
            }
            let rect = NSRect(
                x: number(rectValue["x"]),
                y: number(rectValue["y"]),
                width: number(rectValue["width"]),
                height: number(rectValue["height"])
            )
            guard !identifier.isEmpty,
                  !text.isEmpty,
                  rect.minX.isFinite,
                  rect.minY.isFinite,
                  rect.width.isFinite,
                  rect.height.isFinite,
                  rect.width > 0,
                  rect.height > 0 else {
                return nil
            }
            return BrowserScreenshotProbe(
                identifier: identifier,
                text: text,
                rect: rect,
                foreground: foreground,
                background: background
            )
        }
        return BrowserScreenshotProbeSet(
            viewportSize: viewportSize,
            probes: probes
        )
    }

    private func color(
        from value: [String: Any]
    ) -> BrowserScreenshotRGBA? {
        let color = BrowserScreenshotRGBA(
            red: number(value["red"]),
            green: number(value["green"]),
            blue: number(value["blue"]),
            alpha: number(value["alpha"])
        )
        guard color.red.isFinite,
              color.green.isFinite,
              color.blue.isFinite,
              color.alpha.isFinite,
              (0...1).contains(color.red),
              (0...1).contains(color.green),
              (0...1).contains(color.blue),
              (0...1).contains(color.alpha) else {
            return nil
        }
        return color
    }

    private func number(_ value: Any?) -> CGFloat {
        switch value {
        case let number as NSNumber:
            return CGFloat(number.doubleValue)
        case let double as Double:
            return CGFloat(double)
        case let int as Int:
            return CGFloat(int)
        default:
            return .nan
        }
    }

    private func forceAppKitLayout(for webView: WKWebView) {
        let presentationView = webView.cmuxBrowserViewportPresentationView
        webView.needsLayout = true
        presentationView.needsLayout = true
        webView.cmuxBrowserViewportAttachmentSuperview?.needsLayout = true
        webView.cmuxBrowserViewportAttachmentSuperview?.layoutSubtreeIfNeeded()
        presentationView.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        presentationView.displayIfNeeded()
        webView.displayIfNeeded()
        CATransaction.flush()
    }

    private func waitForAnimationFrames(in webView: WKWebView) async throws {
        try await BrowserScreenshotAnimationFrameWaiter(
            webView: webView,
            timeout: animationFrameTimeout
        ).wait(script: animationFrameFlushScript)
    }

    private func evaluate(
        _ script: String,
        in webView: WKWebView,
        timeout: TimeInterval
    ) async throws -> Any? {
        try await BrowserScreenshotJavaScriptRequest(
            webView: webView,
            timeout: timeout
        ).evaluate(script: script)
    }

    private var animationFrameFlushScript: String {
        """
        const doc = document.documentElement;
        const body = document.body;
        if (doc) {
          doc.getBoundingClientRect();
          void doc.scrollWidth;
          void doc.scrollHeight;
        }
        if (body) {
          body.getBoundingClientRect();
          void body.scrollWidth;
          void body.scrollHeight;
        }
        await new Promise((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(resolve));
        });
        return document.readyState;
        """
    }

    private var layoutFlushScript: String {
        """
        (() => {
          const doc = document.documentElement;
          const body = document.body;
          if (doc) {
            doc.getBoundingClientRect();
            void doc.scrollWidth;
            void doc.scrollHeight;
          }
          if (body) {
            body.getBoundingClientRect();
            void body.scrollWidth;
            void body.scrollHeight;
          }
          return document.readyState;
        })();
        """
    }

    private var probeScript: String {
        """
        (() => {
          const viewportWidth = window.innerWidth || 0;
          const viewportHeight = window.innerHeight || 0;
          if (!document.body || viewportWidth <= 0 || viewportHeight <= 0) {
            return { viewportWidth, viewportHeight, probes: [] };
          }
          if (document.fonts && document.fonts.status !== "loaded") {
            return { viewportWidth, viewportHeight, probes: [] };
          }

          // The native timeout can abandon its continuation, but it cannot
          // interrupt JavaScript already running in WebKit. Keep the synchronous
          // DOM/layout work independently bounded in the content process.
          const workDeadline = performance.now() + 100;
          const workBudgetExpired = () => performance.now() >= workDeadline;
          let remainingCharacterMeasurements = 512;

          // This cache lives only for this synchronous script invocation, so
          // computed styles cannot survive a DOM/style mutation or a later collection.
          const styleCache = new WeakMap();
          const styleFor = (element) => {
            let style = styleCache.get(element);
            if (!style) {
              style = getComputedStyle(element);
              styleCache.set(element, style);
            }
            return style;
          };

          const parseColor = (value) => {
            if (!value) return null;
            const match = value.match(
              /^rgba?\\(\\s*([\\d.]+)(?:\\s+|\\s*,\\s*)([\\d.]+)(?:\\s+|\\s*,\\s*)([\\d.]+)(?:\\s*\\/\\s*|\\s*,\\s*)?([\\d.]*)\\s*\\)$/i
            );
            if (!match) return null;
            const alpha = match[4] === "" ? 1 : Number(match[4]);
            const color = {
              red: Number(match[1]) / 255,
              green: Number(match[2]) / 255,
              blue: Number(match[3]) / 255,
              alpha
            };
            return Object.values(color).every(Number.isFinite) ? color : null;
          };

          const composite = (foreground, background) => {
            const alpha = foreground.alpha + background.alpha * (1 - foreground.alpha);
            if (alpha <= 0) return null;
            return {
              red: (
                foreground.red * foreground.alpha
                + background.red * background.alpha * (1 - foreground.alpha)
              ) / alpha,
              green: (
                foreground.green * foreground.alpha
                + background.green * background.alpha * (1 - foreground.alpha)
              ) / alpha,
              blue: (
                foreground.blue * foreground.alpha
                + background.blue * background.alpha * (1 - foreground.alpha)
              ) / alpha,
              alpha
            };
          };

          const hasComplexCompositing = (element) => {
            for (let current = element; current; current = current.parentElement) {
              const style = styleFor(current);
              if (
                Number(style.opacity) < 0.999
                || style.filter !== "none"
                || (style.backdropFilter && style.backdropFilter !== "none")
                || style.mixBlendMode !== "normal"
                || style.backgroundClip === "text"
                || style.webkitBackgroundClip === "text"
                || (style.maskImage && style.maskImage !== "none")
                || (style.webkitMaskImage && style.webkitMaskImage !== "none")
                || (style.clipPath && style.clipPath !== "none")
              ) {
                return true;
              }
            }
            return false;
          };

          const solidBackground = (element) => {
            const layers = [];
            for (let current = element; current; current = current.parentElement) {
              const style = styleFor(current);
              if (style.backgroundImage !== "none") {
                return null;
              }
              const color = parseColor(style.backgroundColor);
              if (!color) return null;
              if (color.alpha > 0) layers.push(color);
              if (color.alpha >= 0.999) break;
            }
            if (layers.length === 0 || layers[layers.length - 1].alpha < 0.999) {
              return null;
            }
            let result = layers[layers.length - 1];
            for (let index = layers.length - 2; index >= 0; index -= 1) {
              result = composite(layers[index], result);
              if (!result) return null;
            }
            return result;
          };

          const luminance = (color) => {
            const channel = (value) => (
              value <= 0.04045
                ? value / 12.92
                : Math.pow((value + 0.055) / 1.055, 2.4)
            );
            return (
              0.2126 * channel(color.red)
              + 0.7152 * channel(color.green)
              + 0.0722 * channel(color.blue)
            );
          };

          const contrast = (first, second) => {
            const firstLuminance = luminance(first);
            const secondLuminance = luminance(second);
            return (
              Math.max(firstLuminance, secondLuminance) + 0.05
            ) / (
              Math.min(firstLuminance, secondLuminance) + 0.05
            );
          };

          const nodeIdentifier = (node, characterIndex) => {
            const components = [];
            for (let current = node; current && current !== document; current = current.parentNode) {
              const parent = current.parentNode;
              if (!parent) break;
              components.push(Array.prototype.indexOf.call(parent.childNodes, current));
            }
            return `${components.reverse().join(".")}:${characterIndex}`;
          };

          const preferredCharacterRange = (node) => {
            // Choose by rendered geometry instead of script. Wide glyphs are
            // safe for bounded pixel sampling; narrow glyphs remain
            // inconclusive rather than risking a false blank.
            let codeUnitIndex = 0;
            let visitedCharacters = 0;
            let widest = null;
            for (const character of node.data) {
              if (
                visitedCharacters >= 64
                || remainingCharacterMeasurements <= 0
                || workBudgetExpired()
              ) {
                break;
              }
              visitedCharacters += 1;
              const characterIndex = codeUnitIndex;
              const characterLength = character.length;
              codeUnitIndex += characterLength;
              if (/^\\s+$/u.test(character)) continue;

              remainingCharacterMeasurements -= 1;
              const range = document.createRange();
              range.setStart(node, characterIndex);
              range.setEnd(node, characterIndex + characterLength);
              const rect = range.getBoundingClientRect();
              if (rect.width < 2 || rect.height < 6) continue;

              const aspectRatio = rect.width / rect.height;
              const candidate = {
                characterIndex,
                characterLength,
                rect,
                aspectRatio
              };
              if (!widest || aspectRatio > widest.aspectRatio) {
                widest = candidate;
              }
              if (aspectRatio >= 0.45) return candidate;
            }
            return widest && widest.aspectRatio >= 0.25 ? widest : null;
          };

          const layerPaints = (element) => {
            const style = styleFor(element);
            if (
              style.display === "none"
              || style.visibility !== "visible"
              || Number(style.opacity) <= 0
            ) {
              return false;
            }
            const background = parseColor(style.backgroundColor);
            if (
              (background && background.alpha > 0)
              || style.backgroundImage !== "none"
              || style.boxShadow !== "none"
              || style.filter !== "none"
              || (style.backdropFilter && style.backdropFilter !== "none")
            ) {
              return true;
            }
            return (
              element instanceof HTMLCanvasElement
              || element instanceof HTMLImageElement
              || element instanceof HTMLVideoElement
              || element instanceof SVGElement
              || element instanceof HTMLIFrameElement
              || element instanceof HTMLObjectElement
              || element instanceof HTMLEmbedElement
            );
          };

          // Pointer-transparent layers do not appear in elementFromPoint, yet
          // can legitimately paint over text. Scan the whole document when it
          // fits inside the work budget; a fixed element limit would disable
          // verification on otherwise inexpensive, complex application DOMs.
          // Exhausting either budget makes the capture inconclusive.
          const elementWalker = document.createTreeWalker(
            document.body,
            NodeFilter.SHOW_ELEMENT
          );
          const passivePaintedRects = [];
          let visitedElements = 0;
          for (
            let element = elementWalker.nextNode();
            element;
            element = elementWalker.nextNode()
          ) {
            visitedElements += 1;
            if ((visitedElements & 31) === 0 && workBudgetExpired()) {
              return { viewportWidth, viewportHeight, probes: [] };
            }
            const style = styleFor(element);
            if (style.pointerEvents !== "none" || !layerPaints(element)) continue;
            const rect = element.getBoundingClientRect();
            if (
              rect.width <= 0
              || rect.height <= 0
              || rect.right <= 0
              || rect.bottom <= 0
              || rect.left >= viewportWidth
              || rect.top >= viewportHeight
            ) {
              continue;
            }
            passivePaintedRects.push(rect);
            if (passivePaintedRects.length > 64) {
              return { viewportWidth, viewportHeight, probes: [] };
            }
          }

          const candidates = [];
          const occupiedCells = new Set();
          const walker = document.createTreeWalker(
            document.body,
            NodeFilter.SHOW_TEXT,
            {
              acceptNode(node) {
                return node.data.trim()
                  ? NodeFilter.FILTER_ACCEPT
                  : NodeFilter.FILTER_REJECT;
              }
            }
          );
          let visited = 0;
          for (let node = walker.nextNode(); node && visited < 500; node = walker.nextNode()) {
            if (remainingCharacterMeasurements <= 0 || workBudgetExpired()) break;
            visited += 1;
            const element = node.parentElement;
            if (!element) continue;
            const style = styleFor(element);
            if (
              style.display === "none"
              || style.visibility !== "visible"
              || style.contentVisibility === "hidden"
              || Number(style.opacity) < 0.999
              || Number.parseFloat(style.fontSize) < 6
              || hasComplexCompositing(element)
            ) {
              continue;
            }

            const characterRange = preferredCharacterRange(node);
            if (!characterRange) continue;
            const {
              characterIndex,
              rect
            } = characterRange;
            if (
              rect.left < 0
              || rect.top < 0
              || rect.right > viewportWidth
              || rect.bottom > viewportHeight
            ) {
              continue;
            }

            const centerX = rect.left + rect.width / 2;
            const centerY = rect.top + rect.height / 2;
            const hit = document.elementFromPoint(centerX, centerY);
            if (!hit || (hit !== element && !element.contains(hit))) continue;
            if (
              passivePaintedRects.some((layerRect) => (
                centerX >= layerRect.left
                && centerX <= layerRect.right
                && centerY >= layerRect.top
                && centerY <= layerRect.bottom
              ))
            ) {
              continue;
            }
            const column = Math.min(3, Math.floor(centerX / viewportWidth * 4));
            const row = Math.min(3, Math.floor(centerY / viewportHeight * 4));
            const cell = `${column}:${row}`;
            if (occupiedCells.has(cell)) continue;

            const background = solidBackground(element);
            // WebKit's text-fill color is inherited and reflects the actual
            // glyph fill. A transparent gradient/clipped fill is inconclusive.
            const rawForeground = parseColor(style.webkitTextFillColor || style.color);
            if (!background || !rawForeground || rawForeground.alpha < 0.35) continue;
            const foreground = composite(rawForeground, background);
            if (!foreground || contrast(foreground, background) < 3) continue;

            occupiedCells.add(cell);
            const text = node.data.replace(/\\s+/g, " ").trim().slice(0, 80);
            candidates.push({
              node,
              characterIndex,
              text,
              rect: {
                x: rect.left,
                y: rect.top,
                width: rect.width,
                height: rect.height
              },
              foreground,
              background,
              centerX,
              centerY
            });
            if (candidates.length === 12) break;
          }

          if (candidates.length === 0) {
            return { viewportWidth, viewportHeight, probes: [] };
          }

          return {
            viewportWidth,
            viewportHeight,
            probes: candidates.map(({
              node,
              characterIndex,
              centerX,
              centerY,
              ...probe
            }) => ({
              identifier: nodeIdentifier(node, characterIndex),
              ...probe
            }))
          };
        })();
        """
    }
}
