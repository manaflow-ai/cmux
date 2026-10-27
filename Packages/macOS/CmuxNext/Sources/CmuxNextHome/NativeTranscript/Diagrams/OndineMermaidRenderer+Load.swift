import Foundation
import JavaScriptCore

extension OndineMermaidRenderer {
    /// A context with the shims, Ondine (`code`, the text of `script`) and the render function; nil
    /// when the script fails. Slow (it compiles Ondine's WebAssembly): never on the main thread.
    nonisolated static func load(_ code: String, from script: URL) -> JSValue? {
        guard let context = JSContext() else { return nil }
        context.evaluateScript(ondineHostShims)
        context.evaluateScript(code, withSourceURL: script)
        let render = context.evaluateScript("""
            (function () {
              var renderer = ondine.create({ modules: { all: ondine.wasm } });
              return function (source, maxWidth, fontSize) {
                try {
                  var r = renderer.render(source, { maxWidth: maxWidth, fontSize: fontSize, idPrefix: "cmux-home-" });
                  return { svg: r.svg, width: r.width, height: r.height };
                } catch (e) {
                  return null;
                }
              };
            })()
            """)
        // An uncaught exception stays in `exception`: the script or the shims did not load.
        guard context.exception == nil, let render, render.isObject else { return nil }
        return render
    }
}
