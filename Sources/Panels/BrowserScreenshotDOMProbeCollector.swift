import AppKit
import CmuxBrowser
import WebKit

/// Reads stable, high-contrast text probes from one `WKWebView`.
@MainActor
final class BrowserScreenshotDOMProbeCollector {
    private weak var webView: WKWebView?
    private let animationFrameTimeout: TimeInterval
    private var animationFrameContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var animationFrameTimers: [UUID: Timer] = [:]

    init(webView: WKWebView, animationFrameTimeout: TimeInterval = 1) {
        self.webView = webView
        self.animationFrameTimeout = animationFrameTimeout
    }

    func synchronize(waitForAnimationFrame: Bool) async {
        guard let webView else { return }
        forceAppKitLayout(for: webView)

        if waitForAnimationFrame {
            await waitForAnimationFrames(in: webView)
        } else {
            do {
                _ = try await webView.evaluateJavaScript(
                    layoutFlushScript,
                    contentWorld: .defaultClient
                )
            } catch {
#if DEBUG
                cmuxDebugLog("browser.screenshot.synchronize.failed error=\(error.localizedDescription)")
#endif
            }
        }

        forceAppKitLayout(for: webView)
    }

    func collect() async -> BrowserScreenshotFrameVerifier.ProbeSet? {
        guard let webView else { return nil }
        do {
            guard let value = try await webView.evaluateJavaScript(
                probeScript,
                contentWorld: .defaultClient
            ) as? [String: Any] else {
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
    ) -> BrowserScreenshotFrameVerifier.ProbeSet? {
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

        let probes = values.compactMap { probeValue -> BrowserScreenshotFrameVerifier.Probe? in
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
            return BrowserScreenshotFrameVerifier.Probe(
                identifier: identifier,
                text: text,
                rect: rect,
                foreground: foreground,
                background: background
            )
        }
        return BrowserScreenshotFrameVerifier.ProbeSet(
            viewportSize: viewportSize,
            probes: probes
        )
    }

    private func color(
        from value: [String: Any]
    ) -> BrowserScreenshotFrameVerifier.RGBA? {
        let color = BrowserScreenshotFrameVerifier.RGBA(
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
    }

    private func waitForAnimationFrames(in webView: WKWebView) async {
        let operationID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                animationFrameContinuations[operationID] = continuation
                animationFrameTimers[operationID] = Timer.scheduledTimer(
                    withTimeInterval: animationFrameTimeout,
                    repeats: false
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.finishAnimationFrameWait(operationID)
                    }
                }
                webView.callAsyncJavaScript(
                    animationFrameFlushScript,
                    arguments: [:],
                    in: nil,
                    in: .defaultClient
                ) { [weak self] result in
                    Task { @MainActor [weak self] in
#if DEBUG
                        if case .failure(let error) = result {
                            cmuxDebugLog(
                                "browser.screenshot.synchronize.failed error=\(error.localizedDescription)"
                            )
                        }
#endif
                        self?.finishAnimationFrameWait(operationID)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishAnimationFrameWait(operationID)
            }
        }
    }

    private func finishAnimationFrameWait(_ operationID: UUID) {
        animationFrameTimers.removeValue(forKey: operationID)?.invalidate()
        animationFrameContinuations.removeValue(forKey: operationID)?.resume()
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

          // elementFromPoint intentionally ignores pointer-events:none layers,
          // even though they still paint. Treat pages too large to audit, and
          // text covered by any painted pointerless box, as inconclusive.
          const overlayElements = document.body.querySelectorAll("*");
          if (overlayElements.length > 2000) {
            return { viewportWidth, viewportHeight, probes: [] };
          }
          const pointerlessPaintedBoxes = [];
          for (const element of overlayElements) {
            const style = styleFor(element);
            if (
              style.pointerEvents !== "none"
              || style.display === "none"
              || style.visibility !== "visible"
              || Number(style.opacity) < 0.001
            ) {
              continue;
            }
            const background = parseColor(style.backgroundColor);
            const paintsBox = (
              (background && background.alpha > 0.001)
              || style.backgroundImage !== "none"
              || style.boxShadow !== "none"
              || style.filter !== "none"
              || (style.backdropFilter && style.backdropFilter !== "none")
            );
            if (!paintsBox) continue;
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
            pointerlessPaintedBoxes.push({ element, rect });
          }
          const hasPointerlessPaintAt = (element, x, y) => (
            pointerlessPaintedBoxes.some(({ element: overlay, rect }) => (
              !overlay.contains(element)
              && x >= rect.left
              && x <= rect.right
              && y >= rect.top
              && y <= rect.bottom
            ))
          );

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

          const preferredCharacterIndex = (text) => {
            // A coarse sparse grid can miss the ink in narrow glyphs such as
            // "i" or "1". Skip those nodes instead of risking a false blank.
            const preferred = /[MW@#%&8BDEFHKLNPRSTXZ2345679]/;
            for (let index = 0; index < text.length; index += 1) {
              if (preferred.test(text[index])) return index;
            }
            return -1;
          };

          const candidates = [];
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

            const characterIndex = preferredCharacterIndex(node.data);
            if (characterIndex < 0) continue;
            const range = document.createRange();
            range.setStart(node, characterIndex);
            range.setEnd(node, characterIndex + 1);
            const rect = range.getBoundingClientRect();
            if (
              rect.width < 2
              || rect.height < 6
              || rect.left < 0
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
            if (hasPointerlessPaintAt(element, centerX, centerY)) continue;

            const background = solidBackground(element);
            const rawForeground = parseColor(style.color);
            if (!background || !rawForeground || rawForeground.alpha < 0.35) continue;
            const foreground = composite(rawForeground, background);
            if (!foreground || contrast(foreground, background) < 3) continue;

            const text = node.data.replace(/\\s+/g, " ").trim().slice(0, 80);
            candidates.push({
              identifier: nodeIdentifier(node, characterIndex),
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
          }

          const probes = [];
          const occupiedCells = new Set();
          for (const candidate of candidates) {
            const column = Math.min(3, Math.floor(candidate.centerX / viewportWidth * 4));
            const row = Math.min(3, Math.floor(candidate.centerY / viewportHeight * 4));
            const key = `${column}:${row}`;
            if (occupiedCells.has(key)) continue;
            occupiedCells.add(key);
            probes.push(candidate);
            if (probes.length === 12) break;
          }
          if (probes.length < 12) {
            for (const candidate of candidates) {
              if (probes.includes(candidate)) continue;
              probes.push(candidate);
              if (probes.length === 12) break;
            }
          }

          return {
            viewportWidth,
            viewportHeight,
            probes: probes.map(({ centerX, centerY, ...probe }) => probe)
          };
        })();
        """
    }
}
