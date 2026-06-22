import Foundation
import Testing
@testable import CmuxBrowser

/// Locks the byte-shape of the user-action JavaScript builders lifted from
/// `TerminalController`'s `v2BrowserClick`/`Type`/`Fill`/`Press`/`Check`/`Scroll`
/// methods into ``BrowserControlService``. These assert the literal interpolation
/// points and the shared-helper inclusion that the worker-lane wire output
/// depends on.
@Suite("BrowserControlService interaction scripts")
struct BrowserControlServiceInteractionScriptsTests {
    let service = BrowserControlService()

    @Test("shared helper constants carry the cmux event dispatchers")
    func helperConstants() {
        #expect(BrowserControlService.inputHelpers.contains("function __cmuxClick(el)"))
        #expect(BrowserControlService.inputHelpers.contains("function __cmuxHover(el)"))
        #expect(BrowserControlService.inputHelpers.contains("function __cmuxSetChecked(el,desired)"))
        #expect(BrowserControlService.inputHelpers.contains("function __cmuxKey(target,type,key)"))
        #expect(BrowserControlService.reactCompatibleSetValue.contains("nativeSetter.call(el, newValue);"))
    }

    @Test("click/dblclick/hover bodies embed the input helpers and interpolate the selector")
    func pointerActions() {
        let click = service.clickScript(selectorLiteral: "\"#go\"")
        #expect(click.hasPrefix("(() => {"))
        #expect(click.contains("function __cmuxClick(el)"))
        #expect(click.contains("document.querySelector(\"#go\")"))
        #expect(click.contains("__cmuxClick(el);"))

        let dbl = service.doubleClickScript(selectorLiteral: "\"#go\"")
        #expect(dbl.contains("__cmuxMouse(el, 'dblclick', c, 0, 2);"))

        let hover = service.hoverScript(selectorLiteral: "\"#go\"")
        #expect(hover.contains("__cmuxHover(el);"))

        // focus deliberately omits the input helpers (legacy body had no helpers).
        let focus = service.focusElementScript(selectorLiteral: "\"#go\"")
        #expect(!focus.contains("function __cmuxClick"))
        #expect(focus.contains("if (typeof el.focus === 'function') el.focus();"))
    }

    @Test("type/fill embed the native setter and the correct inputType")
    func valueActions() {
        let type = service.typeScript(selectorLiteral: "\"#in\"", textLiteral: "\"hi\"")
        #expect(type.contains("const chunk = String(\"hi\");"))
        #expect(type.contains("inputType: 'insertText'"))
        #expect(type.contains("nativeSetter.call(el, newValue);"))

        let fill = service.fillScript(selectorLiteral: "\"#in\"", textLiteral: "\"hi\"")
        #expect(fill.contains("const newValue = String(\"hi\");"))
        #expect(fill.contains("inputType: 'insertReplacementText'"))
    }

    @Test("press/keydown/keyup interpolate the key and embed helpers")
    func keyActions() {
        let press = service.pressScript(keyLiteral: "\"Enter\"")
        #expect(press.contains("const k = String(\"Enter\");"))
        #expect(press.contains("function __cmuxKey(target,type,key)"))
        #expect(press.contains("__cmuxKey(target, 'keydown', k);"))
        #expect(press.contains("target.form.requestSubmit"))

        let down = service.keyDownScript(keyLiteral: "\"a\"")
        #expect(down.contains("__cmuxKey(target, 'keydown', k);"))
        #expect(!down.contains("'keyup'"))

        let up = service.keyUpScript(keyLiteral: "\"a\"")
        #expect(up.contains("__cmuxKey(target, 'keyup', k);"))
        #expect(!up.contains("'keydown'"))
    }

    @Test("check/uncheck select the desired boolean state")
    func checkAction() {
        let check = service.setCheckedScript(selectorLiteral: "\"#cb\"", checked: true)
        #expect(check.contains("__cmuxSetChecked(el, true);"))
        #expect(check.contains("if (el.checked !== true)"))

        let uncheck = service.setCheckedScript(selectorLiteral: "\"#cb\"", checked: false)
        #expect(uncheck.contains("__cmuxSetChecked(el, false);"))
        #expect(uncheck.contains("if (el.checked !== false)"))
    }

    @Test("select interpolates the option value")
    func selectAction() {
        let select = service.selectOptionScript(selectorLiteral: "\"#sel\"", valueLiteral: "\"v2\"")
        #expect(select.contains("const newValue = String(\"v2\");"))
        #expect(select.contains("el.dispatchEvent(new Event('change', { bubbles: true }));"))
    }

    @Test("scroll element vs window and scroll_into_view")
    func scrollActions() {
        let element = service.scrollElementScript(selectorLiteral: "\"#box\"", dx: 5, dy: -3)
        #expect(element.contains("el.scrollBy({ left: 5, top: -3, behavior: 'instant' });"))
        #expect(element.contains("el.scrollLeft += 5;"))

        let window = service.scrollWindowScript(dx: 0, dy: 100)
        #expect(window == "window.scrollBy({ left: 0, top: 100, behavior: 'instant' }); ({ ok: true })")

        let into = service.scrollIntoViewScript(selectorLiteral: "\"#box\"")
        #expect(into.contains("el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });"))
    }

    @Test("highlight outlines the element and restores the prior styles")
    func highlightAction() {
        let highlight = service.highlightScript(selectorLiteral: "\"#box\"")
        #expect(highlight.hasPrefix("(() => {"))
        #expect(highlight.contains("const el = document.querySelector(\"#box\");"))
        #expect(highlight.contains("el.style.outline = '3px solid #ff9f0a';"))
        #expect(highlight.contains("el.style.outlineOffset = '2px';"))
        #expect(highlight.contains("el.style.outline = prev;"))
        #expect(highlight.contains("el.style.outlineOffset = prevOffset;"))
        #expect(highlight.contains("}, 1200);"))
        // highlight deliberately omits the input helpers (legacy body had none).
        #expect(!highlight.contains("function __cmuxClick"))
    }
}
