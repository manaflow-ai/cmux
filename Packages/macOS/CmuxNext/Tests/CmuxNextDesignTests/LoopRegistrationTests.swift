import Foundation
import Testing

/// Every infinite Core Animation loop in CmuxNext's sources runs through a ``LoopHost``
/// (p14-energy-056): a loop added with a bare `layer.add` keeps the render server drawing frames
/// for a hidden view or an occluded window. A source check, as `rg 'repeatCount = .infinity'`,
/// judged per call site: the function that builds each infinite loop is a maker, and every call
/// of a maker is the make closure of an `.attach(_:key:)` call, sits in a function that returns
/// the loop on (a maker in its turn), or sits in one of ``gatedHosts``.
struct LoopRegistrationTests {
    /// How many infinite loops CmuxNext has (plans/cmux-next/chrome-parity/p14-energy.md): a new one
    /// registers with a ``LoopHost`` and raises this count.
    private static let expectedSites = 10

    /// The functions (`File.swift:function`) that add a loop they did not get through an attach,
    /// each with what keeps the loop off while nobody sees it. Adding through
    /// `LoopVisibility.add(_:to:forKey:clock:)` is not that: it only sets the loop's phase.
    static let gatedHosts: [String: String] = [
        "StatusIndicatorLayer.swift:updateAnimation":
            "adds the loop of a plan made with animates: true, which each of statusIndicatorHosts makes only while it is visible",
    ]

    /// The files that make a `StatusIndicatorLayer`, each with how its plan stays still while hidden.
    static let statusIndicatorHosts: [String: String] = [
        "StatusIndicatorView.swift": "applyPlan animates only while visibilityNode, under the window's WindowVisibilitySource node, is visible",
        "TabCell+LazyLayers.swift":
            "spinnerPlan (TabCell+StatusIndicator) animates only while isWindowVisible, which TabStripView's WindowVisibilityObserver sets from the window's WindowVisibilitySource node",
        "TabCell+StatusBadge.swift": "statusBadgePlan is made with animates: false",
    ]

    @Test func everyInfiniteLoopRegistersWithALoopHost() throws {
        let report = Self.scan(try Self.sources())
        #expect(report.sites.count == Self.expectedSites, "infinite loops in CmuxNext: \(report.sites)")
        #expect(report.makers.isSuperset(of: ["spinAnimation", "pulseAnimation", "wiggleAnimation", "twinkle", "rise", "loop", "waveAnimation"]),
                "makers: \(report.makers.sorted())")
        #expect(report.unregistered.isEmpty, "infinite loops added outside a LoopHost: \(report.unregistered)")
    }

    /// One attach in a file proves nothing about the file's other calls: a bare `layer.add` of a
    /// factory's loop next to an attached one is flagged, and so is `LoopVisibility.add`.
    @Test func aBareLoopIsFlaggedInAFileThatAlsoAttaches() {
        let report = Self.scan([
            Self.factory,
            Source(path: "CmuxNextSidebar/Views/Spinner.swift", text: """
            final class Spinner: NSView {
                private let loops = LoopVisibility("spinner")
                func start(_ a: CALayer, _ b: CALayer, _ c: CALayer) {
                    loops.attach(a, key: "spin") { Motion.indicators.spinAnimation() }
                    if let loop = Motion.indicators.spinAnimation() { b.add(loop, forKey: "spin") }
                    if let loop = Motion.indicators.spinAnimation() { LoopVisibility.add(loop, to: c, forKey: "spin", clock: SpinnerClock()) }
                }
            }
            """),
        ])
        #expect(report.sites == ["CmuxNextDesign/Motion/Motion+AppKit.swift:4"])
        #expect(report.unregistered == ["CmuxNextSidebar/Views/Spinner.swift:5 (spinAnimation)", "CmuxNextSidebar/Views/Spinner.swift:6 (spinAnimation)"])
    }

    /// A make closure over several lines counts, and a function that returns the loop is a maker
    /// whose own callers are judged the same way.
    @Test func aWrapperOfAFactoryIsJudgedAtItsOwnCallers() {
        let report = Self.scan([
            Self.factory,
            Source(path: "CmuxNextSidebar/Views/Card.swift", text: """
            final class Card: NSView {
                private let loops = LoopVisibility("card")
                func sweep(_ bar: CALayer) {
                    loops.attach(bar, key: "sweep") { [weak self] in
                        self?.sweepLoop()
                    }
                }
                private func sweepLoop() -> CAAnimation? {
                    Motion.indicators.spinAnimation()
                }
                func bare(_ bar: CALayer) {
                    if let loop = sweepLoop() { bar.add(loop, forKey: "sweep") }
                }
            }
            """),
        ])
        #expect(report.makers == ["spinAnimation", "sweepLoop"])
        #expect(report.unregistered == ["CmuxNextSidebar/Views/Card.swift:12 (sweepLoop)"])
    }

    private static let factory = Source(path: "CmuxNextDesign/Motion/Motion+AppKit.swift", text: """
    extension MotionGate {
        public func spinAnimation() -> CAAnimation? {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.repeatCount = .infinity
            return spin
        }
    }
    """)

    // MARK: - The scan

    /// A source file, its path under `Sources/` (`CmuxNextDesign/Motion/LoopVisibility.swift`), with
    /// comments and string contents blanked.
    struct Source {
        let path: String
        let code: [String]
        let chars: [[Character]]

        init(path: String, text: String) {
            self.path = path
            code = LoopRegistrationTests.stripped(text.components(separatedBy: "\n"))
            chars = code.map { Array($0) }
        }

        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        var module: String { path.split(separator: "/").first.map(String.init) ?? path }
    }

    struct Report {
        /// Each `repeatCount = .infinity`, as `path:line`.
        var sites: [String] = []
        /// The functions that build or return an infinite loop.
        var makers: Set<String> = []
        /// The calls of a maker that reach no host, as `path:line (maker)`.
        var unregistered: [String] = []
    }

    private enum Scope { case file, module, everywhere }

    private struct Function {
        let source: Int
        let name: String
        let scope: Scope
        let returnsAnimation: Bool
    }

    private struct Call {
        let source: Int
        let line: Int
        let column: Int
    }

    static func scan(_ sources: [Source]) -> Report {
        var report = Report()
        var pending: [Function] = []
        var seen: Set<String> = []
        func enqueue(_ function: Function) {
            guard seen.insert("\(sources[function.source].path):\(function.name)").inserted else { return }
            report.makers.insert(function.name)
            pending.append(function)
        }
        for (index, source) in sources.enumerated() {
            for (line, text) in source.chars.enumerated() {
                guard let column = firstIndex(of: Array("repeatCount = .infinity"), in: text) else { continue }
                let site = "\(source.path):\(line + 1)"
                report.sites.append(site)
                if let function = enclosingFunction(in: sources, source: index, line: line, column: column) {
                    enqueue(function)
                } else {
                    report.unregistered.append("\(site) (in no function)")
                }
            }
        }
        while let maker = pending.popLast() {
            for call in calls(of: maker, in: sources) {
                let source = sources[call.source]
                if isAttachMake(source.chars, line: call.line, column: call.column) { continue }
                let caller = enclosingFunction(in: sources, source: call.source, line: call.line, column: call.column)
                if let caller, gatedHosts["\(source.name):\(caller.name)"] != nil { continue }
                if let caller, caller.returnsAnimation {
                    enqueue(caller)
                    continue
                }
                report.unregistered.append("\(source.path):\(call.line + 1) (\(maker.name))")
            }
        }
        for source in sources where !source.name.hasPrefix("StatusIndicatorLayer") && statusIndicatorHosts[source.name] == nil {
            for (line, text) in source.code.enumerated() where text.contains("StatusIndicatorLayer(") {
                report.unregistered.append("\(source.path):\(line + 1) (a StatusIndicatorLayer outside statusIndicatorHosts)")
            }
        }
        report.unregistered.sort()
        return report
    }

    /// Whether the call at `column` of `line` is in the make closure of an `.attach(_:key:)` call:
    /// the innermost open brace before it ends `.attach(…key:…)` or `.attach(…make:`.
    private static func isAttachMake(_ lines: [[Character]], line: Int, column: Int) -> Bool {
        var depth = 0
        var number = line
        var end = column
        while number >= 0, line - number <= 40 {
            let chars = lines[number]
            var index = min(end, chars.count) - 1
            while index >= 0 {
                if chars[index] == "}" {
                    depth += 1
                } else if chars[index] == "{" {
                    guard depth == 0 else {
                        depth -= 1
                        index -= 1
                        continue
                    }
                    let prefix = String(chars[..<index]).trimmingCharacters(in: .whitespaces)
                    guard let attach = prefix.range(of: ".attach(", options: .backwards) else { return false }
                    let arguments = prefix[attach.upperBound...]
                    return (prefix.hasSuffix(")") && arguments.contains("key:")) || prefix.hasSuffix("make:")
                }
                index -= 1
            }
            number -= 1
            if number >= 0 { end = lines[number].count }
        }
        return false
    }

    /// The function the code at `column` of `line` sits in: the nearest `func` above it that is
    /// indented less than every line between (a nested helper such as the wiggle's `turn`, at the
    /// site's own indent, is skipped).
    private static func enclosingFunction(in sources: [Source], source index: Int, line: Int, column: Int) -> Function? {
        let source = sources[index]
        if let function = declaredFunction(in: source, source: index, line: line, before: column) { return function }
        var bound = indentation(source.chars[line])
        for number in stride(from: line - 1, through: 0, by: -1) {
            let trimmed = source.code[number].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(")") else { continue }
            let indent = indentation(source.chars[number])
            if indent < bound, let function = declaredFunction(in: source, source: index, line: number, before: nil) { return function }
            bound = min(bound, indent)
        }
        return nil
    }

    /// The function declared on `line` (before `column`, when given).
    private static func declaredFunction(in source: Source, source index: Int, line: Int, before column: Int?) -> Function? {
        let chars = source.chars[line]
        guard let start = firstIndex(of: Array("func "), in: chars), start < (column ?? chars.count),
              start == 0 || chars[start - 1] == " " else { return nil }
        let name = String(chars[(start + 5)...].prefix { isIdentifier($0) })
        guard !name.isEmpty else { return nil }
        let modifiers = String(chars[..<start])
        let scope: Scope = modifiers.contains("private") ? .file
            : modifiers.contains("public") || modifiers.contains("package") ? .everywhere : .module
        var header = ""
        for number in line..<min(line + 6, source.code.count) {
            header += source.code[number]
            if source.code[number].contains("{") { break }
        }
        return Function(source: index, name: name, scope: scope, returnsAnimation: header.contains("-> CAAnimation"))
    }

    /// Every call of `function` where it can be called from: `name(` after no identifier character,
    /// not its own declaration.
    private static func calls(of function: Function, in sources: [Source]) -> [Call] {
        let needle = Array(function.name + "(")
        var found: [Call] = []
        for (index, source) in sources.enumerated() {
            switch function.scope {
            case .file: guard index == function.source else { continue }
            case .module: guard source.module == sources[function.source].module else { continue }
            case .everywhere: break
            }
            for (line, chars) in source.chars.enumerated() where chars.count >= needle.count {
                for start in 0...(chars.count - needle.count) where Array(chars[start..<(start + needle.count)]) == needle {
                    guard start == 0 || !isIdentifier(chars[start - 1]) else { continue }
                    guard !String(chars[..<start]).trimmingCharacters(in: .whitespaces).hasSuffix("func") else { continue }
                    found.append(Call(source: index, line: line, column: start))
                }
            }
        }
        return found
    }

    private static func firstIndex(of needle: [Character], in chars: [Character]) -> Int? {
        guard chars.count >= needle.count else { return nil }
        return (0...(chars.count - needle.count)).first { Array(chars[$0..<($0 + needle.count)]) == needle }
    }

    private static func isIdentifier(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_"
    }

    private static func indentation(_ chars: [Character]) -> Int {
        chars.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// The lines with `//` comments cut and string contents (multi-line ones too) blanked, so a
    /// comment or a string never reads as code.
    static func stripped(_ lines: [String]) -> [String] {
        var inMultiline = false
        return lines.map { line in
            if line.contains("\"\"\"") {
                inMultiline.toggle()
                return ""
            }
            guard !inMultiline else { return "" }
            var out = ""
            var inString = false
            var escaped = false
            var previous: Character = " "
            for char in line {
                if inString {
                    if escaped {
                        escaped = false
                    } else if char == "\\" {
                        escaped = true
                    } else if char == "\"" {
                        inString = false
                        out.append(char)
                        previous = char
                        continue
                    }
                    out.append(" ")
                    continue
                }
                if char == "/", previous == "/" {
                    out.removeLast()
                    return out
                }
                if char == "\"" { inString = true }
                out.append(char)
                previous = char
            }
            return out
        }
    }

    private static func sources() throws -> [Source] {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/CmuxNextDesign").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no Sources/CmuxNextDesign above \(#filePath)")
            root = parent
        }
        let sourcesRoot = root.appendingPathComponent("Sources")
        let base = sourcesRoot.resolvingSymlinksInPath().path + "/"
        let walker = try #require(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        let sources = try walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { url in
            let full = url.resolvingSymlinksInPath().path
            return Source(path: full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full, text: try String(contentsOf: url, encoding: .utf8))
        }
        // A path the scan cannot place in its module would hide that module's calls from it.
        try #require(sources.allSatisfy { !$0.path.hasPrefix("/") }, "a source outside \(base)")
        return sources
    }
}
