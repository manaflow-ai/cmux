// Extend the Element interface to include moveBefore
declare global {
  interface Element {
    moveBefore?(node: Node, child: Node | null): void;
  }
}

type IframeEntry = {
  iframe: HTMLIFrameElement;
  wrapper: HTMLDivElement;
  url: string;
  lastUsed: number;
  isVisible: boolean;
  allow?: string;
  sandbox?: string;
};

interface MountOptions {
  className?: string;
  style?: React.CSSProperties;
  allow?: string;
  sandbox?: string;
}

const UNITLESS_CSS_PROPERTIES = new Set<string>([
  "animation-iteration-count",
  "border-image-outset",
  "border-image-slice",
  "border-image-width",
  "box-flex",
  "box-flex-group",
  "box-ordinal-group",
  "column-count",
  "columns",
  "flex",
  "flex-grow",
  "flex-negative",
  "flex-order",
  "flex-positive",
  "flex-shrink",
  "grid-area",
  "grid-column",
  "grid-column-end",
  "grid-column-span",
  "grid-column-start",
  "grid-row",
  "grid-row-end",
  "grid-row-span",
  "grid-row-start",
  "font-weight",
  "line-clamp",
  "line-height",
  "opacity",
  "order",
  "orphans",
  "tab-size",
  "widows",
  "z-index",
  "zoom",
  "fill-opacity",
  "flood-opacity",
  "stop-opacity",
  "stroke-dasharray",
  "stroke-dashoffset",
  "stroke-miterlimit",
  "stroke-opacity",
  "stroke-width",
]);

/**
 * PersistentIframeManager uses a different approach:
 * - All iframes stay in a persistent container
 * - We use CSS to position them over the target container
 * - This avoids DOM moves entirely, preventing reload
 */
class PersistentIframeManager {
  private iframes = new Map<string, IframeEntry>();
  private maxIframes = 10;
  private container: HTMLDivElement | null = null;
  private resizeObserver: ResizeObserver;
  private activeIframeKey: string | null = null;
  private debugMode = false;

  constructor() {
    // Create resize observer for syncing positions
    this.resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const key = entry.target.getAttribute("data-iframe-target");
        if (key) {
          if (this.debugMode) {
            console.log(`[ResizeObserver] Syncing position for ${key}`);
          }
          this.syncIframePosition(key);
        }
      }
    });

    this.initializeContainer();
  }

  private initializeContainer() {
    if (typeof document === "undefined") return;

    const init = () => {
      this.container = document.createElement("div");
      this.container.id = "persistent-iframe-container";
      this.container.style.cssText = `
        position: fixed;
        top: 0;
        left: 0;
        width: 0;
        height: 0;
        pointer-events: none;
        z-index: var(--z-iframe, 9998);
      `;
      document.body.appendChild(this.container);
    };

    if (document.body) {
      init();
    } else {
      document.addEventListener("DOMContentLoaded", init);
    }
  }

  /**
   * Get or create an iframe
   */
  getOrCreateIframe(
    key: string,
    url: string,
    options?: { allow?: string; sandbox?: string },
  ): HTMLIFrameElement {
    const existing = this.iframes.get(key);

    if (existing) {
      existing.lastUsed = Date.now();
      if (options?.allow !== undefined && existing.allow !== options.allow) {
        existing.iframe.allow = options.allow;
        existing.allow = options.allow;
      }
      if (
        options?.sandbox !== undefined &&
        existing.sandbox !== options.sandbox
      ) {
        existing.iframe.setAttribute("sandbox", options.sandbox);
        existing.sandbox = options.sandbox;
      }
      if (existing.url !== url) {
        existing.iframe.src = url;
        existing.url = url;
      }
      return existing.iframe;
    }

    // Create wrapper div
    const wrapper = document.createElement("div");
    wrapper.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      visibility: hidden;
      pointer-events: none;
      overflow: hidden;
      transform: translate(-100vw, -100vh);
      width: 100vw;
      height: 100vh;
    `;
    wrapper.setAttribute("data-iframe-key", key);

    // Create iframe
    const iframe = document.createElement("iframe");
    iframe.style.cssText = `
      width: 100%;
      height: 100%;
      border: 0;
    `;

    // Apply permissions if provided
    if (options?.allow) {
      iframe.allow = options.allow;
    }

    // Apply sandbox if provided
    if (options?.sandbox) {
      iframe.setAttribute("sandbox", options.sandbox);
    }

    iframe.src = url;

    wrapper.appendChild(iframe);

    // Add to container
    if (this.container) {
      this.container.appendChild(wrapper);
    }

    const entry: IframeEntry = {
      iframe,
      wrapper,
      url,
      lastUsed: Date.now(),
      isVisible: false,
      allow: options?.allow,
      sandbox: options?.sandbox,
    };

    this.iframes.set(key, entry);
    this.moveIframeOffscreen(entry);
    this.cleanupOldIframes();

    return iframe;
  }

  /**
   * Show iframe over a target element
   */
  mountIframe(
    key: string,
    targetElement: HTMLElement,
    options?: MountOptions,
  ): () => void {
    if (this.debugMode) console.log(`[Mount] Starting mount for ${key}`);

    const entry = this.iframes.get(key);
    if (!entry) {
      throw new Error(`Iframe with key "${key}" not found`);
    }

    // Fix #1: Hide currently active iframe before showing new one
    if (this.activeIframeKey && this.activeIframeKey !== key) {
      const activeEntry = this.iframes.get(this.activeIframeKey);
      if (activeEntry && activeEntry.isVisible) {
        if (this.debugMode)
          console.log(`[Mount] Hiding active iframe ${this.activeIframeKey}`);
        this.blurIframe(activeEntry);
        activeEntry.wrapper.style.visibility = "hidden";
        activeEntry.wrapper.style.pointerEvents = "none";
        activeEntry.isVisible = false;
      }
    }

    // Mark target element
    targetElement.setAttribute("data-iframe-target", key);

    // Apply styles to wrapper
    if (options?.className) {
      entry.wrapper.className = options.className;
    }

    // First sync position while hidden
    this.syncIframePosition(key);

    // Then make visible after a microtask to ensure position is set
    requestAnimationFrame(() => {
      // Apply base styles without clobbering layout-related properties (width/height/transform)
      entry.wrapper.style.position = "fixed";
      entry.wrapper.style.top = "0";
      entry.wrapper.style.left = "0";
      entry.wrapper.style.right = "";
      entry.wrapper.style.bottom = "";
      entry.wrapper.style.visibility = "visible";
      entry.wrapper.style.pointerEvents = "auto";
      entry.wrapper.style.overflow = "hidden";

      if (options?.style) {
        for (const [styleKey, styleValue] of Object.entries(options.style)) {
          if (styleValue === undefined || styleValue === null) {
            continue;
          }

          const cssKey = styleKey.replace(
            /[A-Z]/g,
            (match) => `-${match.toLowerCase()}`,
          );
          const cssValue =
            typeof styleValue === "number" &&
            !UNITLESS_CSS_PROPERTIES.has(cssKey)
              ? `${styleValue}px`
              : String(styleValue);
          entry.wrapper.style.setProperty(cssKey, cssValue);
        }
      }

      // Ensure the iframe wrapper reflects any layout changes triggered by new styles
      this.syncIframePosition(key);

      entry.isVisible = true;
      this.activeIframeKey = key;
      if (this.debugMode) console.log(`[Mount] Iframe ${key} is now visible`);
    });

    entry.lastUsed = Date.now();

    // Start observing the target element
    this.resizeObserver.observe(targetElement);

    // Listen for scroll events
    const scrollHandler = () => {
      if (this.debugMode) console.log(`[Scroll] Syncing position for ${key}`);
      this.syncIframePosition(key);
    };
    const scrollableParents = this.getScrollableParents(targetElement);
    scrollableParents.forEach((parent) => {
      parent.addEventListener("scroll", scrollHandler, { passive: true });
    });

    // Also sync on window resize
    window.addEventListener("resize", scrollHandler);

    // Return cleanup function
    return () => {
      if (this.debugMode) console.log(`[Unmount] Starting unmount for ${key}`);

      this.blurIframe(entry);
      targetElement.removeAttribute("data-iframe-target");
      entry.wrapper.style.visibility = "hidden";
      entry.wrapper.style.pointerEvents = "none";
      entry.isVisible = false;

      if (this.activeIframeKey === key) {
        this.activeIframeKey = null;
      }

      this.resizeObserver.unobserve(targetElement);
      scrollableParents.forEach((parent) => {
        parent.removeEventListener("scroll", scrollHandler);
      });
      window.removeEventListener("resize", scrollHandler);
    };
  }

  /**
   * Sync iframe position with target element
   */
  private syncIframePosition(key: string) {
    const entry = this.iframes.get(key);
    if (!entry) return;

    const targetElement = document.querySelector(
      `[data-iframe-target="${key}"]`,
    );
    if (!targetElement || !(targetElement instanceof HTMLElement)) {
      this.moveIframeOffscreen(entry);
      return;
    }

    const rect = targetElement.getBoundingClientRect();
    const computedStyle = window.getComputedStyle(targetElement);

    const borderLeft = parseFloat(computedStyle.borderLeftWidth) || 0;
    const borderRight = parseFloat(computedStyle.borderRightWidth) || 0;
    const borderTop = parseFloat(computedStyle.borderTopWidth) || 0;
    const borderBottom = parseFloat(computedStyle.borderBottomWidth) || 0;

    const width = Math.max(0, rect.width - borderLeft - borderRight);
    const height = Math.max(0, rect.height - borderTop - borderBottom);

    if (width < 1 || height < 1) {
      this.moveIframeOffscreen(entry);
      return;
    }

    // Update wrapper position using transform, keeping resize handles unobstructed
    entry.wrapper.style.transform = `translate(${rect.left + borderLeft}px, ${rect.top + borderTop}px)`;
    entry.wrapper.style.width = `${width}px`;
    entry.wrapper.style.height = `${height}px`;
  }

  /**
   * Get all scrollable parent elements
   */
  private getScrollableParents(element: HTMLElement): HTMLElement[] {
    const parents: HTMLElement[] = [];
    let current = element.parentElement;

    while (current) {
      const style = window.getComputedStyle(current);
      if (
        style.overflow === "auto" ||
        style.overflow === "scroll" ||
        style.overflowX === "auto" ||
        style.overflowX === "scroll" ||
        style.overflowY === "auto" ||
        style.overflowY === "scroll"
      ) {
        parents.push(current);
      }
      current = current.parentElement;
    }

    // Always include window
    parents.push(document.documentElement);

    return parents;
  }

  /**
   * Hide iframe
   */
  unmountIframe(key: string): void {
    const entry = this.iframes.get(key);
    if (!entry) return;

    this.blurIframe(entry);
    entry.wrapper.style.visibility = "hidden";
    entry.wrapper.style.pointerEvents = "none";
    this.moveIframeOffscreen(entry);
    entry.isVisible = false;

    if (this.activeIframeKey === key) {
      this.activeIframeKey = null;
    }
  }

  /**
   * Preload an iframe
   */
  preloadIframe(
    key: string,
    url: string,
    options?: { allow?: string; sandbox?: string },
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      const iframe = this.getOrCreateIframe(key, url, options);

      const handleLoad = () => {
        iframe.removeEventListener("load", handleLoad);
        iframe.removeEventListener("error", handleError);
        resolve();
      };

      const handleError = () => {
        iframe.removeEventListener("load", handleLoad);
        iframe.removeEventListener("error", handleError);
        reject(new Error(`Failed to load iframe: ${url}`));
      };

      if (iframe.contentWindow && iframe.src === url) {
        resolve();
        return;
      }

      iframe.addEventListener("load", handleLoad);
      iframe.addEventListener("error", handleError);
    });
  }

  /**
   * Remove an iframe completely
   */
  removeIframe(key: string): void {
    const entry = this.iframes.get(key);
    if (!entry) return;

    this.handoffFocusBeforeRemoval(entry);
    if (entry.wrapper.parentElement) {
      entry.wrapper.parentElement.removeChild(entry.wrapper);
    }

    if (this.activeIframeKey === key) {
      this.activeIframeKey = null;
    }

    this.iframes.delete(key);
  }

  /**
   * Clean up old iframes
   */
  private cleanupOldIframes(): void {
    if (this.iframes.size <= this.maxIframes) return;

    const sorted = Array.from(this.iframes.entries())
      .filter(([, entry]) => !entry.isVisible)
      .sort(([, a], [, b]) => a.lastUsed - b.lastUsed);

    const toRemove = sorted.slice(
      0,
      Math.max(0, this.iframes.size - this.maxIframes),
    );

    for (const [key] of toRemove) {
      this.removeIframe(key);
    }
  }

  /**
   * Preload multiple iframes
   */
  async preloadMultiple(
    entries: Array<{
      key: string;
      url: string;
      allow?: string;
      sandbox?: string;
    }>,
  ): Promise<void> {
    await Promise.all(
      entries.map(({ key, url, allow, sandbox }) =>
        this.preloadIframe(key, url, { allow, sandbox }),
      ),
    );
  }

  /**
   * Get all loaded iframe keys
   */
  getLoadedKeys(): string[] {
    return Array.from(this.iframes.keys());
  }

  /**
   * Clear all iframes
   */
  clear(): void {
    for (const key of this.iframes.keys()) {
      this.removeIframe(key);
    }
  }

  /**
   * Enable or disable debug mode
   */
  setDebugMode(enabled: boolean): void {
    this.debugMode = enabled;
  }

  private moveIframeOffscreen(entry: IframeEntry): void {
    if (typeof window === "undefined" || typeof document === "undefined") {
      return;
    }

    const viewportWidth = Math.max(
      1,
      window.innerWidth || 0,
      document.documentElement?.clientWidth ?? 0,
    );
    const viewportHeight = Math.max(
      1,
      window.innerHeight || 0,
      document.documentElement?.clientHeight ?? 0,
    );

    entry.wrapper.style.width = `${viewportWidth}px`;
    entry.wrapper.style.height = `${viewportHeight}px`;
    entry.wrapper.style.transform = `translate(-${viewportWidth}px, -${viewportHeight}px)`;
  }

  private blurIframe(entry: IframeEntry): void {
    if (typeof document === "undefined") {
      return;
    }

    if (document.activeElement !== entry.iframe) {
      return;
    }

    try {
      entry.iframe.blur();
    } catch {
      // ignore focus errors
    }

    try {
      entry.iframe.contentWindow?.blur?.();
    } catch {
      // ignore cross-origin focus errors
    }
  }

  private handoffFocusBeforeRemoval(entry: IframeEntry): void {
    if (typeof document === "undefined" || typeof window === "undefined") {
      return;
    }

    if (document.activeElement !== entry.iframe) {
      return;
    }

    this.blurIframe(entry);

    window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => {
        const nextActiveKey = this.activeIframeKey;
        const nextActiveEntry =
          (nextActiveKey ? this.iframes.get(nextActiveKey) : null) ??
          Array.from(this.iframes.values()).find((candidate) => candidate.isVisible) ??
          null;

        const focusTargets: Array<() => void> = [];

        if (nextActiveEntry) {
          focusTargets.push(() => {
            try {
              nextActiveEntry.iframe.focus({ preventScroll: true });
            } catch {
              // ignore focus errors
            }
          });
          focusTargets.push(() => {
            try {
              nextActiveEntry.iframe.contentWindow?.focus?.();
            } catch {
              // ignore cross-origin focus errors
            }
          });
        }

        focusTargets.push(() => {
          try {
            (document.body ?? document.documentElement)?.focus?.();
          } catch {
            // ignore body focus errors
          }
        });
        focusTargets.push(() => {
          try {
            window.focus?.();
          } catch {
            // ignore window focus errors
          }
        });

        for (const focusTarget of focusTargets) {
          try {
            focusTarget();
            if (
              nextActiveEntry &&
              document.activeElement === nextActiveEntry.iframe
            ) {
              break;
            }
          } catch {
            // ignore focus target errors
          }
        }
      });
    });
  }
}

// Export singleton instance
export const persistentIframeManager = new PersistentIframeManager();
