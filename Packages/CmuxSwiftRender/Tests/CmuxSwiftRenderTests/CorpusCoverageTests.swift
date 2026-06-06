import Foundation
import SwiftParser
import SwiftSyntax
import Testing
@testable import CmuxSwiftRender

/// Iteration harness: runs every authored sidebar in `Corpus/` through the
/// interpreter against a rich stub data context, and statically lists the
/// view constructors / modifiers / methods the corpus uses that the
/// interpreter does not yet support. This is the to-do list driving the
/// interpreter toward "can render every proposed sidebar". Always passes;
/// read its printed report.
@Suite struct CorpusCoverageTests {
    @Test func reportCorpusCoverage() {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Corpus")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let interp = SwiftViewInterpreter()
        let ctx = corpusStubContext()

        let supportedCalls: Set<String> = [
            "Text", "VStack", "HStack", "ZStack", "HSplitView", "Button", "Image",
            "Spacer", "Divider", "Rectangle", "RoundedRectangle", "Capsule", "Circle",
            "ForEach", "Reorderable", "cmux", "log", "Color", "ScrollView", "openURL",
            "LazyVStack", "LazyHStack", "Group", "EmptyView", "List", "Section",
            "Label", "Array", "Int", "Double", "String", "Ellipse", "UnevenRoundedRectangle",
            "min", "max", "abs",
            "Grid", "GridRow", "LazyVGrid", "LazyHGrid", "ViewThatFits", "GridItem",
            "ProgressView", "Gauge", "Menu", "AnyView",
            "LinearGradient", "RadialGradient", "AngularGradient", "Gradient",
        ]
        let supportedMembers: Set<String> = [
            "font", "bold", "fontWeight", "foregroundColor", "foregroundStyle", "fill",
            "tint", "padding", "background", "cornerRadius", "opacity", "lineLimit",
            "frame", "onTapGesture",
            "filter", "map", "flatMap", "reduce", "sorted", "first", "contains", "count",
            "reversed", "prefix", "isEmpty", "hasPrefix", "hasSuffix", "uppercased",
            "lowercased", "split", "formatted", "currency", "notation", "percent", "strikethrough", "system",
            "indices", "enumerated", "dropFirst", "dropLast", "suffix",
            "joined", "capitalized", "replacingOccurrences", "trimmingCharacters",
            "italic", "monospaced", "monospacedDigit", "fontDesign", "underline",
            "multilineTextAlignment", "textCase", "truncationMode",
            "shadow", "border", "blur", "offset", "scaleEffect", "rotationEffect",
            "zIndex", "brightness", "contrast", "saturation", "grayscale",
            "clipShape", "clipped", "fixedSize", "layoutPriority", "degrees", "radians",
            "overlay", "mask", "safeAreaInset",
            "imageScale", "symbolRenderingMode", "symbolVariant",
            "stroke", "strokeBorder", "trim",
            "contextMenu", "help", "disabled", "keyboardShortcut",
            "redacted", "unredacted", "accessibilityLabel", "accessibilityHint",
            "accessibilityValue", "accessibilityHidden", "scrollIndicators",
            "scrollContentBackground", "aspectRatio", "scaledToFit", "scaledToFill", "resizable",
        ]

        var unsupportedCalls: [String: Int] = [:]
        var unsupportedMembers: [String: Int] = [:]
        var coverage: [String] = []

        for file in files {
            let src = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let node = interp.evaluate(src, state: ctx)
            let count = node.map(Self.nodeCount) ?? 0
            let collector = SymbolCollector(viewMode: .sourceAccurate)
            collector.walk(Parser.parse(source: src))
            // User-defined funcs in the same file are supported via the
            // interpreter's function table; don't flag them.
            let userFuncs = collector.declaredFunctions
            for (name, n) in collector.declCalls where !supportedCalls.contains(name) && !userFuncs.contains(name) {
                unsupportedCalls[name, default: 0] += n
            }
            for (name, n) in collector.memberCalls where !supportedMembers.contains(name) {
                unsupportedMembers[name, default: 0] += n
            }
            coverage.append(String(format: "%@ %4d nodes  %@", node != nil ? "OK " : "NIL", count, file.lastPathComponent))
        }

        print("\n===== CORPUS RENDER COVERAGE (\(files.count) sidebars) =====")
        coverage.forEach { print($0) }
        print("\n===== UNSUPPORTED CONSTRUCTORS / FUNCTIONS =====")
        for (k, n) in unsupportedCalls.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) { print("\(n)x  \(k)") }
        print("\n===== UNSUPPORTED MODIFIERS / METHODS =====")
        for (k, n) in unsupportedMembers.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) { print("\(n)x  \(k)") }
        print("===== END =====\n")
    }

    private static func nodeCount(_ node: RenderNode) -> Int {
        1 + node.children.reduce(0) { $0 + nodeCount($1) }
    }
}

/// Collects function-call symbols: `Name(...)` (declCalls) and `.member(...)`
/// (memberCalls), to compare against the interpreter's supported sets.
private final class SymbolCollector: SyntaxVisitor {
    var declCalls: [String: Int] = [:]
    var memberCalls: [String: Int] = [:]
    var declaredFunctions: Set<String> = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        declaredFunctions.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            declCalls[ref.baseName.text, default: 0] += 1
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            memberCalls[member.declName.baseName.text, default: 0] += 1
        }
        return .visitChildren
    }
}

/// A generous read-only data context so corpus sidebars have data to bind to;
/// fields the personas plausibly reference. Unknown identifiers simply resolve
/// to nil (empty) and do not crash.
private func corpusStubContext() -> [String: SwiftValue] {
    func obj(_ d: [String: SwiftValue]) -> SwiftValue { .object(d) }
    func s(_ v: String) -> SwiftValue { .string(v) }
    func i(_ v: Int) -> SwiftValue { .int(v) }
    func b(_ v: Bool) -> SwiftValue { .bool(v) }

    let workspaces: SwiftValue = .array((0..<4).map { n in
        obj([
            "id": s("ws-\(n)"), "title": s("workspace \(n)"), "selected": b(n == 0),
            "directory": s("/Users/me/proj\(n)"), "branch": s("main"), "dirty": b(n % 2 == 0),
            "tabs": .array((0..<3).map { t in obj(["id": s("t-\(n)-\(t)"), "title": s("tab \(t)"), "focused": b(t == 0)]) }),
        ])
    })
    func list(_ count: Int, _ make: (Int) -> [String: SwiftValue]) -> SwiftValue { .array((0..<count).map { obj(make($0)) }) }

    return [
        "workspaces": workspaces,
        "workspaceCount": i(4),
        "selectedTitle": s("workspace 0"),
        "clock": obj(["time": s("12:34:56"), "hour": i(12), "minute": i(34), "second": i(56), "epoch": i(1_780_000_000)]),
        "git": obj(["branch": s("main"), "dirty": b(true), "ahead": i(2), "behind": i(0), "staged": i(1)]),
        "services": list(3) { ["id": s("svc-\($0)"), "name": s("service \($0)"), "port": i(3000 + $0), "up": b($0 != 1), "healthy": b($0 == 0)] },
        "ports": list(3) { ["port": i(3000 + $0), "owner": s("node")] },
        "pulls": list(3) { ["number": i(100 + $0), "title": s("PR \($0)"), "ciState": s($0 == 0 ? "passing" : "failing"), "needsMyReview": b($0 == 1)] },
        "ci": obj(["state": s("passing"), "runs": i(12)]),
        "builds": list(2) { ["id": s("b\($0)"), "status": s($0 == 0 ? "passing" : "running")] },
        "gpus": list(2) { ["index": i($0), "utilPct": i(40 + $0 * 30), "vramUsedGB": i(8 + $0), "tempC": i(60 + $0)] },
        "host": obj(["ramUsedGB": i(24), "ramTotalGB": i(64), "cpuPct": i(35), "diskPct": i(55)]),
        "alerts": list(3) { ["id": s("a\($0)"), "severity": s($0 == 0 ? "sev1" : "sev3"), "title": s("alert \($0)"), "acked": b($0 != 0)] },
        "runbooks": list(2) { ["id": s("rb\($0)"), "title": s("runbook \($0)"), "url": s("https://x")] },
        "tasks": list(4) { ["id": s("task-\($0)"), "title": s("task \($0)"), "done": b($0 < 2), "lane": s($0 < 2 ? "done" : "todo"), "due": s("Fri")] },
        "notes": s("remember to rebase before EOD"),
        "runs": list(2) { ["id": s("run\($0)"), "step": i(1000 * ($0 + 1)), "loss": .double(0.2), "eta": s("2m")] },
        "datasets": list(2) { ["id": s("ds\($0)"), "name": s("dataset \($0)")] },
        "devices": list(2) { ["id": s("dev\($0)"), "name": s("iPhone \(15 + $0)"), "booted": b($0 == 0)] },
        "simulators": list(2) { ["id": s("sim\($0)"), "name": s("iPhone \(15 + $0) Pro"), "booted": b($0 == 0)] },
        "schemes": .array([s("Debug"), s("Release")]),
        "agents": list(3) { ["id": s("ag\($0)"), "name": s("agent \($0)"), "state": s($0 == 0 ? "running" : "idle"), "costUSD": .double(0.5)] },
        "queue": list(3) { ["id": s("q\($0)"), "title": s("queued \($0)"), "state": s("queued")] },
        "usage": obj(["tokens": i(120_000), "costUSD": .double(3.2)]),
        "palette": .array([s("#FF8800"), s("#34C759"), s("#0A84FF")]),
        "tokens": list(3) { ["name": s("space-\($0)"), "value": s("\(4 * ($0 + 1))pt")] },
        "files": list(3) { ["name": s("chapter\($0).md"), "words": i(800 + $0 * 100)] },
        "wordCount": i(2400),
        "streak": i(5),
        "pomodoro": obj(["remaining": s("18:20"), "block": i(2), "total": i(4)]),
    ]
}
