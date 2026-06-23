import Foundation

/// Curates a cmux.json `editor` object into the Monaco
/// `IStandaloneEditorConstructionOptions` subset cmux forwards to the `cmux
/// edit` webview.
///
/// This is the security + correctness boundary for user-configurable editor
/// options: only an explicit allowlist of viewer/edit-safe keys is forwarded,
/// each type- and enum-validated; model-level or unsafe keys (`model`, `value`,
/// `language`, `theme`, `readOnly`, `automaticLayout`, …) are dropped even when
/// present. It lives in `CmuxFoundation` (rather than the CLI) so it can be unit
/// tested without launching the app: the function is pure (`[String: Any]` in,
/// `[String: Any]` out, no I/O).
///
/// ```swift
/// let options = EditorMonacoOptionCuration.curate([
///   "wordWrap": "on",
///   "minimap": ["enabled": false],
///   "model": ["forbidden": true],   // dropped
/// ])
/// // options == ["wordWrap": "on", "minimap": ["enabled": false]]
/// ```
///
/// Returns an empty dictionary when nothing valid is configured, which lets the
/// webview keep its hardcoded defaults.
public enum EditorMonacoOptionCuration {
    public static func curate(_ section: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]

        func boolOpt(_ key: String) -> Bool? { section[key] as? Bool }
        func intOpt(_ key: String, _ minValue: Int, _ maxValue: Int) -> Int? {
            let raw: Int?
            if let n = section[key] as? Int { raw = n }
            else if let d = section[key] as? Double { raw = Int(d) }
            else { raw = nil }
            guard let value = raw, value >= minValue, value <= maxValue else { return nil }
            return value
        }
        func doubleOpt(_ key: String, _ minValue: Double, _ maxValue: Double) -> Double? {
            let raw: Double?
            if let d = section[key] as? Double { raw = d }
            else if let n = section[key] as? Int { raw = Double(n) }
            else { raw = nil }
            guard let value = raw, value >= minValue, value <= maxValue else { return nil }
            return value
        }
        func enumOpt(_ key: String, _ allowed: Set<String>) -> String? {
            guard let s = section[key] as? String, allowed.contains(s) else { return nil }
            return s
        }

        // Word wrap & layout
        if let v = enumOpt("wordWrap", ["off", "on", "wordWrapColumn", "bounded"]) { out["wordWrap"] = v }
        if let v = intOpt("wordWrapColumn", 1, 10000) { out["wordWrapColumn"] = v }
        if let v = enumOpt("wrappingIndent", ["none", "same", "indent", "deepIndent"]) { out["wrappingIndent"] = v }
        if let v = boolOpt("scrollBeyondLastLine") { out["scrollBeyondLastLine"] = v }
        if let v = boolOpt("smoothScrolling") { out["smoothScrolling"] = v }

        // Indentation & tabs
        if let v = intOpt("tabSize", 1, 64) { out["tabSize"] = v }
        if let v = boolOpt("insertSpaces") { out["insertSpaces"] = v }
        if let v = boolOpt("detectIndentation") { out["detectIndentation"] = v }
        if let v = boolOpt("trimAutoWhitespace") { out["trimAutoWhitespace"] = v }

        // Display & rendering
        if let v = enumOpt("lineNumbers", ["on", "off", "relative", "interval"]) { out["lineNumbers"] = v }
        if let v = enumOpt("renderWhitespace", ["none", "boundary", "selection", "trailing", "all"]) { out["renderWhitespace"] = v }
        if let v = enumOpt("renderLineHighlight", ["none", "gutter", "line", "all"]) { out["renderLineHighlight"] = v }
        if let v = boolOpt("glyphMargin") { out["glyphMargin"] = v }
        if let v = boolOpt("folding") { out["folding"] = v }
        if let v = enumOpt("showFoldingControls", ["always", "never", "mouseover"]) { out["showFoldingControls"] = v }

        // Cursor
        if let v = enumOpt("cursorStyle", ["line", "block", "underline", "line-thin", "block-outline", "underline-thin"]) { out["cursorStyle"] = v }
        if let v = enumOpt("cursorBlinking", ["blink", "smooth", "phase", "expand", "solid"]) { out["cursorBlinking"] = v }
        if let v = enumOpt("cursorSmoothCaretAnimation", ["off", "explicit", "on"]) { out["cursorSmoothCaretAnimation"] = v }

        // Font tweaks not owned by appearance (font family/size/lineHeight stay
        // appearance-derived to avoid a second source of truth).
        if let v = doubleOpt("letterSpacing", -5, 20) { out["letterSpacing"] = v }
        if let v = boolOpt("fontLigatures") { out["fontLigatures"] = v }

        // Selection & interaction
        if let v = boolOpt("roundedSelection") { out["roundedSelection"] = v }
        if let v = boolOpt("columnSelection") { out["columnSelection"] = v }
        if let v = boolOpt("mouseWheelZoom") { out["mouseWheelZoom"] = v }
        if let v = enumOpt("multiCursorModifier", ["ctrlCmd", "alt"]) { out["multiCursorModifier"] = v }

        // minimap (nested)
        if let m = section["minimap"] as? [String: Any] {
            var mm: [String: Any] = [:]
            if let e = m["enabled"] as? Bool { mm["enabled"] = e }
            if let s = m["side"] as? String, ["left", "right"].contains(s) { mm["side"] = s }
            if let r = m["renderCharacters"] as? Bool { mm["renderCharacters"] = r }
            if let n = m["maxColumn"] as? Int, n > 0, n <= 1000 { mm["maxColumn"] = n }
            if !mm.isEmpty { out["minimap"] = mm }
        }

        // bracketPairColorization (nested)
        if let b = section["bracketPairColorization"] as? [String: Any] {
            var bb: [String: Any] = [:]
            if let e = b["enabled"] as? Bool { bb["enabled"] = e }
            if let i = b["independentColorPoolPerBracketType"] as? Bool { bb["independentColorPoolPerBracketType"] = i }
            if !bb.isEmpty { out["bracketPairColorization"] = bb }
        }

        // guides (nested) — bracketPairs accepts bool or the string "active"
        if let g = section["guides"] as? [String: Any] {
            var gg: [String: Any] = [:]
            if let i = g["indentation"] as? Bool { gg["indentation"] = i }
            if let h = g["highlightActiveIndentation"] as? Bool { gg["highlightActiveIndentation"] = h }
            if let bp = g["bracketPairs"] as? Bool { gg["bracketPairs"] = bp }
            else if let bps = g["bracketPairs"] as? String, bps == "active" { gg["bracketPairs"] = "active" }
            if let hb = g["highlightActiveBracketPair"] as? Bool { gg["highlightActiveBracketPair"] = hb }
            if !gg.isEmpty { out["guides"] = gg }
        }

        // stickyScroll (nested)
        if let s = section["stickyScroll"] as? [String: Any] {
            var ss: [String: Any] = [:]
            if let e = s["enabled"] as? Bool { ss["enabled"] = e }
            if let n = s["maxLineCount"] as? Int, n >= 1, n <= 20 { ss["maxLineCount"] = n }
            if !ss.isEmpty { out["stickyScroll"] = ss }
        }

        // rulers — array of positive column numbers
        if let r = section["rulers"] as? [Any] {
            let cols = r.compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }
                .filter { $0 > 0 && $0 <= 10000 }
            if !cols.isEmpty { out["rulers"] = cols }
        }

        return out
    }
}
