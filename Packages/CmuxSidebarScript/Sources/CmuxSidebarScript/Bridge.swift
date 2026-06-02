import Foundation

/// Installs the SwiftUI bridge: style constructors, view constructors, the
/// modifier vocabulary, and a few bare-symbol constants. This is where "support
/// everything in SwiftUI" lives: adding a view or modifier is a single entry
/// here plus a case in `RenderNodeView`.
enum Bridge {
    static func install(into env: LispEnvironment) {
        installConstants(env)
        installStyleConstructors(env)
        installActionConstructors(env)
        installViewConstructors(env)
    }

    private static func builtin(_ name: String, _ env: LispEnvironment,
                                _ body: @escaping ([LispValue], Evaluator) throws -> LispValue) {
        env.define(name, .function(LispFunction(name: name, kind: .builtin(body))))
    }

    // MARK: - Constants

    private static func installConstants(_ env: LispEnvironment) {
        // Bare-symbol shorthands. Everything here is also expressible as a
        // :keyword literal, but these read nicely in font/stack options.
        for w in ["thin", "ultralight", "light", "regular", "medium", "semibold", "bold", "heavy", "black"] {
            env.define(w, .keyword(w))
        }
        for a in ["leading", "center", "trailing", "top", "bottom"] {
            env.define(a, .keyword(a))
        }
        for d in ["monospaced", "rounded", "serif"] {
            env.define(d, .keyword(d))
        }
        env.define("infinity", .double(.infinity))
    }

    // MARK: - Style constructors

    private static func installStyleConstructors(_ env: LispEnvironment) {
        builtin("hex", env) { args, _ in
            guard case .string(let s)? = args.first else {
                throw LispError.type("hex", expected: "a \"#rrggbb\" string", got: args.first ?? .null)
            }
            return .style(.color(.hex(s)))
        }
        builtin("rgb", env) { args, _ in
            guard args.count >= 3 else { throw LispError.arity("rgb", expected: "3 numbers", got: args.count) }
            return .style(.color(.rgba(try Coercion.number(args[0], "rgb"),
                                       try Coercion.number(args[1], "rgb"),
                                       try Coercion.number(args[2], "rgb"), 1)))
        }
        builtin("rgba", env) { args, _ in
            guard args.count >= 4 else { throw LispError.arity("rgba", expected: "4 numbers", got: args.count) }
            return .style(.color(.rgba(try Coercion.number(args[0], "rgba"),
                                       try Coercion.number(args[1], "rgba"),
                                       try Coercion.number(args[2], "rgba"),
                                       try Coercion.number(args[3], "rgba"))))
        }
        builtin("color", env) { args, _ in
            guard let v = args.first else { throw LispError.arity("color", expected: "a name", got: 0) }
            return .style(.color(try Coercion.color(v, "color")))
        }
        builtin("font", env) { args, _ in try .style(.font(fontValue(args))) }
        builtin("gradient", env) { args, _ in try .style(.gradient(gradientValue(args))) }
        builtin("edges", env) { args, _ in try .style(.edges(edgesValue(args))) }
        builtin("shadow", env) { args, _ in try .style(.shadow(shadowValue(args))) }
    }

    private static func installActionConstructors(_ env: LispEnvironment) {
        builtin("open-url", env) { args, _ in
            .style(.action(RNAction(kind: "open-url", payload: ["url": Builtins.display(args.first ?? .null)])))
        }
        builtin("copy-text", env) { args, _ in
            .style(.action(RNAction(kind: "copy", payload: ["text": Builtins.display(args.first ?? .null)])))
        }
    }

    // MARK: - View constructors

    private static func installViewConstructors(_ env: LispEnvironment) {
        builtin("vstack", env) { args, ev in try stack("vstack", args, ev) }
        builtin("hstack", env) { args, ev in try stack("hstack", args, ev) }
        builtin("zstack", env) { args, ev in try stack("zstack", args, ev) }
        builtin("text", env) { args, _ in try text(args) }
        builtin("image", env) { args, _ in try image(args) }
        builtin("label", env) { args, _ in try label(args) }
        builtin("spacer", env) { args, _ in try spacer(args) }
        builtin("divider", env) { args, _ in
            try .node(finish(RenderNode(kind: "divider"), "divider",
                             Coercion.split(args, formName: "divider").options))
        }
        builtin("rectangle", env) { args, _ in try shape("rectangle", args) }
        builtin("capsule", env) { args, _ in try shape("capsule", args) }
        builtin("circle", env) { args, _ in try shape("circle", args) }
        builtin("rounded-rectangle", env) { args, _ in try roundedRectangle(args) }
        builtin("progress-view", env) { args, _ in try progressView(args) }
        builtin("button", env) { args, _ in try button(args) }
        builtin("group", env) { args, _ in
            let split = try Coercion.split(args, formName: "group")
            let node = RenderNode(kind: "group", children: try Coercion.childNodes(split.positional, formName: "group"))
            return .node(try finish(node, "group", split.options))
        }
    }

    // MARK: - View builders

    private static func stack(_ kind: String, _ args: [LispValue], _ ev: Evaluator) throws -> LispValue {
        let split = try Coercion.split(args, formName: kind)
        var node = RenderNode(kind: kind, children: try Coercion.childNodes(split.positional, formName: kind))
        var leftover: [(String, LispValue)] = []
        for (k, v) in split.options {
            switch k {
            case "spacing": node.content["spacing"] = .number(try Coercion.number(v, kind))
            case "alignment": node.content["alignment"] = .alignment(try Coercion.alignment(v, kind))
            default: leftover.append((k, v))
            }
        }
        return .node(try finish(node, kind, leftover))
    }

    private static func text(_ args: [LispValue]) throws -> LispValue {
        let split = try Coercion.split(args, formName: "text")
        let s = split.positional.map { Builtins.display($0) }.joined()
        let node = RenderNode(kind: "text", content: ["text": .string(s)])
        return .node(try finish(node, "text", split.options))
    }

    private static func image(_ args: [LispValue]) throws -> LispValue {
        let split = try Coercion.split(args, formName: "image")
        var node = RenderNode(kind: "image")
        if let sys = split.option("system") {
            node.content["system"] = .string(Builtins.display(sys))
        } else if let name = split.option("name") {
            node.content["name"] = .string(Builtins.display(name))
        } else if let first = split.positional.first {
            node.content["system"] = .string(Builtins.display(first))
        } else {
            throw LispError.arity("image", expected: "a :system or :name", got: 0)
        }
        let leftover = split.options.filter { $0.0 != "system" && $0.0 != "name" }
        return .node(try finish(node, "image", leftover))
    }

    private static func label(_ args: [LispValue]) throws -> LispValue {
        let split = try Coercion.split(args, formName: "label")
        var node = RenderNode(kind: "label")
        let title = split.option("text") ?? split.positional.first ?? .string("")
        node.content["text"] = .string(Builtins.display(title))
        if let sys = split.option("system") { node.content["system"] = .string(Builtins.display(sys)) }
        let leftover = split.options.filter { $0.0 != "text" && $0.0 != "system" }
        return .node(try finish(node, "label", leftover))
    }

    private static func spacer(_ args: [LispValue]) throws -> LispValue {
        let split = try Coercion.split(args, formName: "spacer")
        var node = RenderNode(kind: "spacer")
        if let m = split.option("min") { node.content["min"] = .number(try Coercion.number(m, "spacer")) }
        let leftover = split.options.filter { $0.0 != "min" }
        return .node(try finish(node, "spacer", leftover))
    }

    private static func shape(_ kind: String, _ args: [LispValue]) throws -> LispValue {
        let split = try Coercion.split(args, formName: kind)
        var node = RenderNode(kind: kind)
        try applyShapePaint(&node, split, kind)
        let leftover = split.options.filter { !shapePaintKeys.contains($0.0) }
        return .node(try finish(node, kind, leftover))
    }

    private static func roundedRectangle(_ args: [LispValue]) throws -> LispValue {
        let split = try Coercion.split(args, formName: "rounded-rectangle")
        var node = RenderNode(kind: "rounded-rectangle")
        if let r = split.option("radius") { node.content["radius"] = .number(try Coercion.number(r, "rounded-rectangle")) }
        try applyShapePaint(&node, split, "rounded-rectangle")
        let leftover = split.options.filter { $0.0 != "radius" && !shapePaintKeys.contains($0.0) }
        return .node(try finish(node, "rounded-rectangle", leftover))
    }

    private static let shapePaintKeys: Set<String> = ["fill", "stroke", "stroke-width"]

    private static func applyShapePaint(_ node: inout RenderNode, _ split: SplitArgs, _ form: String) throws {
        if let fill = split.option("fill") { node.content["fill"] = try paint(fill, form) }
        if let stroke = split.option("stroke") { node.content["stroke"] = .color(try Coercion.color(stroke, form)) }
        if let w = split.option("stroke-width") { node.content["stroke-width"] = .number(try Coercion.number(w, form)) }
    }

    private static func progressView(_ args: [LispValue]) throws -> LispValue {
        let split = try Coercion.split(args, formName: "progress-view")
        var node = RenderNode(kind: "progress-view")
        let value = split.option("value") ?? split.positional.first
        if let value { node.content["value"] = .number(try Coercion.number(value, "progress-view")) }
        if let total = split.option("total") { node.content["total"] = .number(try Coercion.number(total, "progress-view")) }
        let leftover = split.options.filter { $0.0 != "value" && $0.0 != "total" }
        return .node(try finish(node, "progress-view", leftover))
    }

    private static func button(_ args: [LispValue]) throws -> LispValue {
        let split = try Coercion.split(args, formName: "button")
        var node = RenderNode(kind: "button", children: try Coercion.childNodes(split.positional, formName: "button"))
        if let action = split.option("action") {
            node.content["action"] = .action(try actionValue(action, "button"))
        }
        let leftover = split.options.filter { $0.0 != "action" }
        return .node(try finish(node, "button", leftover))
    }

    // MARK: - Modifier application

    private static let frameKeys: Set<String> =
        ["width", "height", "min-width", "max-width", "min-height", "max-height", "frame-align"]
    private static let borderKeys: Set<String> = ["border", "border-width"]

    /// Applies leftover `:keyword` options as ordered modifiers. `frame` and
    /// `border` options are coalesced into one modifier each (preserving the
    /// position of their first appearance) so multi-field SwiftUI modifiers stay
    /// correct.
    static func finish(_ base: RenderNode, _ viewName: String, _ options: [(String, LispValue)]) throws -> RenderNode {
        var node = base
        var frameDone = false
        var borderDone = false
        for (key, _) in options {
            if frameKeys.contains(key) {
                if !frameDone {
                    frameDone = true
                    var named: [String: RNValue] = [:]
                    for (k, v) in options where frameKeys.contains(k) { named[k] = try frameField(k, v, viewName) }
                    node = node.adding(RenderModifier("frame", named: named))
                }
                continue
            }
            if borderKeys.contains(key) {
                if !borderDone {
                    borderDone = true
                    var named: [String: RNValue] = [:]
                    for (k, v) in options where borderKeys.contains(k) {
                        named[k] = k == "border" ? .color(try Coercion.color(v, viewName))
                                                  : .number(try Coercion.number(v, viewName))
                    }
                    node = node.adding(RenderModifier("border", named: named))
                }
                continue
            }
            // Re-find the value for this key (last value wins for repeats).
            let value = options.last(where: { $0.0 == key })!.1
            node = try applyModifier(node, key, value, viewName)
        }
        return node
    }

    private static func frameField(_ key: String, _ v: LispValue, _ form: String) throws -> RNValue {
        if key == "frame-align" { return .alignment(try Coercion.alignment(v, form)) }
        return .number(try Coercion.number(v, form))
    }

    private static func applyModifier(_ node: RenderNode, _ key: String, _ v: LispValue, _ viewName: String) throws -> RenderNode {
        switch key {
        case "padding":
            return node.adding(RenderModifier("padding", values: [.edges(try Coercion.edges(v, "padding"))]))
        case "background":
            return node.adding(RenderModifier("background", values: [try paint(v, "background")]))
        case "foreground", "color", "foreground-color":
            return node.adding(RenderModifier("foreground", values: [try paint(v, "foreground")]))
        case "tint":
            return node.adding(RenderModifier("tint", values: [.color(try Coercion.color(v, "tint"))]))
        case "font":
            return node.adding(RenderModifier("font", values: [.font(try fontFromValue(v))]))
        case "corner-radius":
            return node.adding(RenderModifier("corner-radius", values: [.number(try Coercion.number(v, "corner-radius"))]))
        case "opacity":
            return node.adding(RenderModifier("opacity", values: [.number(try Coercion.number(v, "opacity"))]))
        case "blur":
            return node.adding(RenderModifier("blur", values: [.number(try Coercion.number(v, "blur"))]))
        case "rotation":
            return node.adding(RenderModifier("rotation", values: [.number(try Coercion.number(v, "rotation"))]))
        case "line-limit":
            return node.adding(RenderModifier("line-limit", values: [.number(try Coercion.number(v, "line-limit"))]))
        case "kerning", "tracking":
            return node.adding(RenderModifier("kerning", values: [.number(try Coercion.number(v, "kerning"))]))
        case "layout-priority":
            return node.adding(RenderModifier("layout-priority", values: [.number(try Coercion.number(v, "layout-priority"))]))
        case "z-index":
            return node.adding(RenderModifier("z-index", values: [.number(try Coercion.number(v, "z-index"))]))
        case "truncation":
            return node.adding(RenderModifier("truncation", values: [.string(tokenName(v))]))
        case "text-align", "multiline-align":
            return node.adding(RenderModifier("text-align", values: [.alignment(try Coercion.alignment(v, "text-align"))]))
        case "shadow":
            return node.adding(RenderModifier("shadow", values: [.shadow(try shadowFromValue(v))]))
        case "overlay":
            return node.adding(RenderModifier("overlay", values: [.node(try nodeValue(v, "overlay"))]))
        case "offset":
            return node.adding(RenderModifier("offset", values: [try offsetValue(v)]))
        case "bold":
            return node.adding(RenderModifier("bold", values: [.bool(v.isTruthy)]))
        case "italic":
            return node.adding(RenderModifier("italic", values: [.bool(v.isTruthy)]))
        case "underline":
            return node.adding(RenderModifier("underline", values: [.bool(v.isTruthy)]))
        case "strikethrough":
            return node.adding(RenderModifier("strikethrough", values: [.bool(v.isTruthy)]))
        case "monospaced-digit":
            return node.adding(RenderModifier("monospaced-digit", values: [.bool(v.isTruthy)]))
        case "fixed-size":
            return node.adding(RenderModifier("fixed-size", values: [.bool(v.isTruthy)]))
        case "clip":
            return node.adding(RenderModifier("clip", values: [.bool(v.isTruthy)]))
        case "disabled":
            return node.adding(RenderModifier("disabled", values: [.bool(v.isTruthy)]))
        case "help":
            return node.adding(RenderModifier("help", values: [.string(Builtins.display(v))]))
        case "on-tap", "tap":
            return node.adding(RenderModifier("on-tap", values: [.action(try actionValue(v, "on-tap"))]))
        default:
            throw LispError.unknownModifier(key, on: viewName)
        }
    }

    // MARK: - Value coercion for the bridge

    /// A fill/foreground "paint": a color or a gradient, or a view (for
    /// background/overlay layering).
    private static func paint(_ v: LispValue, _ form: String) throws -> RNValue {
        switch v {
        case .style(.gradient(let g)): return .gradient(g)
        case .style(.color(let c)): return .color(c)
        case .node(let n): return .node(n)
        case .string(let s): return .color(Coercion.parseColorString(s))
        case .keyword(let k), .symbol(let k): return .color(Coercion.colorFromName(k))
        default: throw LispError.type(form, expected: "a color, gradient, or view", got: v)
        }
    }

    private static func nodeValue(_ v: LispValue, _ form: String) throws -> RenderNode {
        if case .node(let n) = v { return n }
        throw LispError.type(form, expected: "a view", got: v)
    }

    private static func actionValue(_ v: LispValue, _ form: String) throws -> RNAction {
        if case .style(.action(let a)) = v { return a }
        throw LispError.type(form, expected: "an action", got: v)
    }

    private static func offsetValue(_ v: LispValue) throws -> RNValue {
        guard case .list(let items) = v, items.count == 2 else {
            throw LispError.type("offset", expected: "a (list x y)", got: v)
        }
        return .list([.number(try Coercion.number(items[0], "offset")),
                      .number(try Coercion.number(items[1], "offset"))])
    }

    private static func tokenName(_ v: LispValue) -> String {
        switch v {
        case .keyword(let k), .symbol(let k), .string(let k): return k
        default: return Builtins.display(v)
        }
    }

    private static func fontFromValue(_ v: LispValue) throws -> RNFont {
        switch v {
        case .style(.font(let f)): return f
        case .int(let i): return RNFont(size: Double(i))
        case .double(let d): return RNFont(size: d)
        case .keyword(let k), .symbol(let k), .string(let k): return RNFont(textStyle: k)
        default: throw LispError.type("font", expected: "a font, size, or text style", got: v)
        }
    }

    private static func shadowFromValue(_ v: LispValue) throws -> RNShadow {
        if case .style(.shadow(let s)) = v { return s }
        if let r = v.asDouble { return RNShadow(color: .rgba(0, 0, 0, 0.33), radius: r) }
        throw LispError.type("shadow", expected: "a shadow or radius", got: v)
    }

    // MARK: - Style constructor bodies

    private static func fontValue(_ args: [LispValue]) throws -> RNFont {
        let split = try Coercion.split(args, formName: "font")
        var font = RNFont()
        if let first = split.positional.first, let size = first.asDouble { font.size = size }
        if let s = split.option("size") { font.size = try Coercion.number(s, "font") }
        if let w = split.option("weight") { font.weight = tokenName(w) }
        if let d = split.option("design") { font.design = tokenName(d) }
        if let st = split.option("style") { font.textStyle = tokenName(st) }
        if let it = split.option("italic") { font.italic = it.isTruthy }
        if let md = split.option("monospaced-digit") { font.monospacedDigit = md.isTruthy }
        return font
    }

    private static func gradientValue(_ args: [LispValue]) throws -> RNGradient {
        let split = try Coercion.split(args, formName: "gradient")
        let colors = try split.positional.map { try Coercion.color($0, "gradient") }
        let dir = split.option("direction").map { tokenName($0) } ?? "vertical"
        return RNGradient(colors: colors, direction: RNGradient.Direction(rawValue: dir) ?? .vertical)
    }

    private static func edgesValue(_ args: [LispValue]) throws -> RNEdges {
        let split = try Coercion.split(args, formName: "edges")
        if let first = split.positional.first, let u = first.asDouble, split.options.isEmpty {
            return .uniform(u)
        }
        var e = RNEdges()
        func read(_ key: String) throws -> Double? {
            guard let v = split.option(key) else { return nil }
            return try Coercion.number(v, "edges")
        }
        if let h = try read("horizontal") { e.leading = h; e.trailing = h }
        if let v = try read("vertical") { e.top = v; e.bottom = v }
        if let t = try read("top") { e.top = t }
        if let l = try read("leading") { e.leading = l }
        if let b = try read("bottom") { e.bottom = b }
        if let r = try read("trailing") { e.trailing = r }
        return e
    }

    private static func shadowValue(_ args: [LispValue]) throws -> RNShadow {
        let split = try Coercion.split(args, formName: "shadow")
        let color = try split.option("color").map { try Coercion.color($0, "shadow") } ?? .rgba(0, 0, 0, 0.33)
        let radius = try split.option("radius").map { try Coercion.number($0, "shadow") } ?? 4
        let x = try split.option("x").map { try Coercion.number($0, "shadow") } ?? 0
        let y = try split.option("y").map { try Coercion.number($0, "shadow") } ?? 0
        return RNShadow(color: color, radius: radius, x: x, y: y)
    }
}
