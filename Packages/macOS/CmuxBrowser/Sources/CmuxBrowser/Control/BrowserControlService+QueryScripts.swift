import Foundation

/// JavaScript builders for the browser read-only query commands (`browser.get.*`,
/// `browser.is.*`) and the `browser.frame.select` same-origin iframe probe.
///
/// Every string returned here is byte-identical to the script the corresponding
/// `v2BrowserGet*` / `v2BrowserIs*` / `v2BrowserFrameSelect` method previously
/// assembled inline in `TerminalController`; only the assembly moved into this
/// package, mirroring the `find.*` locator builders in
/// ``BrowserControlService/findScript(finderBody:)`` and the action builders in
/// ``BrowserControlService/clickScript(selectorLiteral:)`` and friends.
///
/// The owning `@MainActor` controller (app side) still owns the panel
/// resolution, the WebKit evaluation seam, the shared selector-action retry loop,
/// the `get.count` `querySelectorAll` read, the `frame.select` per-surface frame
/// cache mutation, and the per-surface element-ref state; it forwards into these
/// pure builders for the script text, so the RPC wire output is unchanged.
///
/// Each builder takes an already-JSON-escaped `selectorLiteral` (produced by
/// ``BrowserControlService/jsonLiteral(_:)`` at the call site, matching the
/// legacy `v2JSONLiteral(selector)` interpolation) so the package never re-derives
/// the selector and the interpolation is identical to the original.
extension BrowserControlService {
    /// Script for `get.text`: reads the matched element's `innerText`/`textContent`.
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func getTextScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          return { ok: true, value: String(el.innerText || el.textContent || '') };
        })()
        """
    }

    /// Script for `get.html`: reads the matched element's `outerHTML`.
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func getHTMLScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          return { ok: true, value: String(el.outerHTML || '') };
        })()
        """
    }

    /// Script for `get.value`: reads the matched element's `value` (or its text
    /// when it has none).
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func getValueScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          const value = ('value' in el) ? el.value : (el.textContent || '');
          return { ok: true, value: String(value || '') };
        })()
        """
    }

    /// Script for `get.attr`: reads the named attribute off the matched element.
    /// - Parameters:
    ///   - selectorLiteral: the JSON-escaped selector literal.
    ///   - attrLiteral: the JSON-escaped attribute-name literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func getAttrScript(selectorLiteral: String, attrLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          return { ok: true, value: el.getAttribute(String(\(attrLiteral))) };
        })()
        """
    }

    /// Script for `get.count`: counts `querySelectorAll` matches for the selector.
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a JavaScript expression evaluating to the match count.
    public func getCountScript(selectorLiteral: String) -> String {
        "document.querySelectorAll(\(selectorLiteral)).length"
    }

    /// Script for `get.box`: reads the matched element's bounding-client rect.
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func getBoxScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          const r = el.getBoundingClientRect();
          return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
        })()
        """
    }

    /// Script for `get.styles` filtered to one CSS property: reads
    /// `getComputedStyle(el).getPropertyValue(property)`.
    /// - Parameters:
    ///   - selectorLiteral: the JSON-escaped selector literal.
    ///   - propertyLiteral: the JSON-escaped property-name literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func getStylesPropertyScript(selectorLiteral: String, propertyLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          const style = getComputedStyle(el);
          return { ok: true, value: style.getPropertyValue(String(\(propertyLiteral))) };
        })()
        """
    }

    /// Script for `get.styles` without a property filter: reads a fixed set of
    /// computed-style fields off the matched element.
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func getStylesSummaryScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          const style = getComputedStyle(el);
          return { ok: true, value: {
            display: style.display,
            visibility: style.visibility,
            opacity: style.opacity,
            color: style.color,
            background: style.background,
            width: style.width,
            height: style.height
          } };
        })()
        """
    }

    /// Script for `is.visible`: reports whether the matched element is rendered
    /// and non-transparent with a positive box.
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func isVisibleScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          const style = getComputedStyle(el);
          const rect = el.getBoundingClientRect();
          const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
          return { ok: true, value: visible };
        })()
        """
    }

    /// Script for `is.enabled`: reports whether the matched element is not
    /// `disabled`.
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func isEnabledScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          const enabled = !el.disabled;
          return { ok: true, value: !!enabled };
        })()
        """
    }

    /// Script for `is.checked`: reports the matched element's `checked` state.
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func isCheckedScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          const checked = ('checked' in el) ? !!el.checked : false;
          return { ok: true, value: checked };
        })()
        """
    }

    /// Probe for `browser.frame.select`: reports whether the selector resolves to
    /// a same-origin frame whose `contentDocument` is reachable.
    ///
    /// Returns `{ ok: true }` for a same-origin frame, `{ ok: false, error }` with
    /// `not_found` / `not_frame` / `cross_origin` otherwise. Byte-identical to the
    /// former inline `v2BrowserFrameSelect` script.
    /// - Parameter selectorLiteral: the JSON-escaped selector literal.
    /// - Returns: a self-invoking JavaScript expression.
    public func frameSelectProbeScript(selectorLiteral: String) -> String {
        """
        (() => {
          const frame = document.querySelector(\(selectorLiteral));
          if (!frame) return { ok: false, error: 'not_found' };
          if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
          try {
            const sameOrigin = !!frame.contentDocument;
            if (!sameOrigin) return { ok: false, error: 'cross_origin' };
          } catch (_) {
            return { ok: false, error: 'cross_origin' };
          }
          return { ok: true };
        })()
        """
    }
}
