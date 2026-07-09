import Foundation
import Testing
@testable import CmuxBrowser

/// Locks the byte-shape of the read-only query JavaScript builders lifted from
/// `TerminalController`'s `v2BrowserGet*` / `v2BrowserIs*` / `v2BrowserFrameSelect`
/// methods into ``BrowserControlService``. Each expectation is the full literal
/// the legacy inline body produced (with the JSON-escaped selector/attr/property
/// interpolated), so a drift in any character of the worker-lane wire script
/// fails the test.
@Suite("BrowserControlService query scripts")
struct BrowserControlServiceQueryScriptsTests {
    let service = BrowserControlService()

    @Test("get.text reads innerText/textContent")
    func getText() {
        #expect(service.getTextScript(selectorLiteral: "\"#a\"") == """
        (() => {
          const el = document.querySelector("#a");
          if (!el) return { ok: false, error: 'not_found' };
          return { ok: true, value: String(el.innerText || el.textContent || '') };
        })()
        """)
    }

    @Test("get.html reads outerHTML")
    func getHTML() {
        #expect(service.getHTMLScript(selectorLiteral: "\"#a\"") == """
        (() => {
          const el = document.querySelector("#a");
          if (!el) return { ok: false, error: 'not_found' };
          return { ok: true, value: String(el.outerHTML || '') };
        })()
        """)
    }

    @Test("get.value falls back to textContent")
    func getValue() {
        #expect(service.getValueScript(selectorLiteral: "\"#a\"") == """
        (() => {
          const el = document.querySelector("#a");
          if (!el) return { ok: false, error: 'not_found' };
          const value = ('value' in el) ? el.value : (el.textContent || '');
          return { ok: true, value: String(value || '') };
        })()
        """)
    }

    @Test("get.attr reads the interpolated attribute name")
    func getAttr() {
        #expect(service.getAttrScript(selectorLiteral: "\"#a\"", attrLiteral: "\"href\"") == """
        (() => {
          const el = document.querySelector("#a");
          if (!el) return { ok: false, error: 'not_found' };
          return { ok: true, value: el.getAttribute(String("href")) };
        })()
        """)
    }

    @Test("get.count counts querySelectorAll matches as a bare expression")
    func getCount() {
        #expect(service.getCountScript(selectorLiteral: "\"#a\"") == "document.querySelectorAll(\"#a\").length")
    }

    @Test("get.box reads the bounding-client rect fields")
    func getBox() {
        #expect(service.getBoxScript(selectorLiteral: "\"#a\"") == """
        (() => {
          const el = document.querySelector("#a");
          if (!el) return { ok: false, error: 'not_found' };
          const r = el.getBoundingClientRect();
          return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
        })()
        """)
    }

    @Test("get.styles property variant reads getPropertyValue")
    func getStylesProperty() {
        #expect(service.getStylesPropertyScript(selectorLiteral: "\"#a\"", propertyLiteral: "\"color\"") == """
        (() => {
          const el = document.querySelector("#a");
          if (!el) return { ok: false, error: 'not_found' };
          const style = getComputedStyle(el);
          return { ok: true, value: style.getPropertyValue(String("color")) };
        })()
        """)
    }

    @Test("get.styles summary variant reads the fixed field set")
    func getStylesSummary() {
        #expect(service.getStylesSummaryScript(selectorLiteral: "\"#a\"") == """
        (() => {
          const el = document.querySelector("#a");
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
        """)
    }

    @Test("is.visible checks display/visibility/opacity/box")
    func isVisible() {
        #expect(service.isVisibleScript(selectorLiteral: "\"#a\"") == """
        (() => {
          const el = document.querySelector("#a");
          if (!el) return { ok: false, error: 'not_found' };
          const style = getComputedStyle(el);
          const rect = el.getBoundingClientRect();
          const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
          return { ok: true, value: visible };
        })()
        """)
    }

    @Test("is.enabled negates disabled")
    func isEnabled() {
        #expect(service.isEnabledScript(selectorLiteral: "\"#a\"") == """
        (() => {
          const el = document.querySelector("#a");
          if (!el) return { ok: false, error: 'not_found' };
          const enabled = !el.disabled;
          return { ok: true, value: !!enabled };
        })()
        """)
    }

    @Test("is.checked reads the checked property")
    func isChecked() {
        #expect(service.isCheckedScript(selectorLiteral: "\"#a\"") == """
        (() => {
          const el = document.querySelector("#a");
          if (!el) return { ok: false, error: 'not_found' };
          const checked = ('checked' in el) ? !!el.checked : false;
          return { ok: true, value: checked };
        })()
        """)
    }

    @Test("frame.select probes for a reachable same-origin frame")
    func frameSelectProbe() {
        #expect(service.frameSelectProbeScript(selectorLiteral: "\"#f\"") == """
        (() => {
          const frame = document.querySelector("#f");
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
        """)
    }
}
