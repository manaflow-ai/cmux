import Foundation
import Testing

/// Leo, 2026-10-12: no stock macOS tooltip bubble in cmux-next; Leo, 2026-10-20: every hover is
/// themed or gone. A view's tooltip goes through `.themedHelp(_:)` (SwiftUI) or
/// `NSView.themedToolTip` / `setThemedToolTipRegions` (AppKit), which `TooltipPresenter` draws.
/// This scans the package's sources for the raw AppKit and SwiftUI calls that draw the stock
/// bubble: `.help(`, `toolTip =`, `setToolTip(` and `addToolTip(`. Comments and string literals
/// are ignored. Allowed: an `NSMenuItem`'s tool tip (native to menus), the tooltip implementation
/// itself (`CmuxNextDesign/Tooltip/`), and a line carrying, or directly under a comment carrying,
/// `// tooltip-native-allow: <reason>`.
@Suite struct NativeTooltipGuardTests {
    static let marker = "tooltip-native-allow:"
    static let exemptDirectory = "CmuxNextDesign/Tooltip/"

    /// The package's `Sources`, from this file's path.
    static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    @Test func noViewDrawsTheStockTooltip() throws {
        let root = Self.sources.standardizedFileURL.path
        let enumerator = try #require(FileManager.default.enumerator(atPath: root))
        var scanned = 0
        var offenders: [String] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift"), !relative.hasPrefix(Self.exemptDirectory) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: root + "/" + relative))
            scanned += 1
            guard Self.mayHoldRawTooltip(data) else { continue }
            let text = try #require(String(data: data, encoding: .utf8), "\(relative) is not UTF-8")
            offenders += Self.violations(in: text).map { "\(relative):\($0.line): \($0.what)" }
        }
        #expect(scanned > 100, "found only \(scanned) Swift files under \(root)")
        #expect(offenders.isEmpty, """
        Raw tooltips draw macOS's stock bubble. Use .themedHelp(_:) / themedToolTip, drop a tooltip \
        that repeats a label or sits on an obvious glyph, or mark a real exception with \
        `// \(Self.marker) <reason>`:
        \(offenders.joined(separator: "\n"))
        """)
    }

    @Test func theScanSeesThroughFormattingAndSkipsCommentsStringsAndMenus() {
        let source = """
        Button("x") {}
            .help ( "Delete" )
        view.toolTip
            = "Hi"
        self.toolTip = nil
        toolTip = label
        segments.setToolTip("Icons", forSegment: 0)
        let item = NSMenuItem(title: "a", action: nil, keyEquivalent: "")
        item.toolTip = "url"
        func decorate(_ entry: NSMenuItem) { entry.toolTip = "why" }
        let toolTip = "a local"
        if a.toolTip == b {}
        // view.toolTip = "in a comment"
        /* .help("in a block") */
        let s = "button.toolTip = \\(x ? ".help(" : "y")"
        // tooltip-native-allow: layers, not views
        strip.toolTip = tip
        other.toolTip = tip // tooltip-native-allow: a reason
        bare.toolTip = tip // tooltip-native-allow:
        """
        let found = Self.violations(in: source).map(\.line)
        #expect(found == [2, 3, 5, 6, 7, 19])
        // The byte prefilter keeps every file the scan could flag, and skips one that only mentions help.
        #expect(Self.mayHoldRawTooltip(Data(source.utf8)))
        for flagged in [".help(\"a\")", "x.help\n  (\"a\")", "x.help /* c */ (\"a\")", "x.help // c\n(\"a\")", "v.toolTip = t",
                        "s.setToolTip(t, forSegment: 0)", "v.addToolTip(r, owner: o, userData: nil)"] {
            #expect(!Self.violations(in: flagged).isEmpty, "the scan missed \(flagged)")
            #expect(Self.mayHoldRawTooltip(Data(flagged.utf8)), "the prefilter skipped \(flagged)")
        }
        #expect(!Self.mayHoldRawTooltip(Data("let helper = 1 // the help text\nhelpers.append(1)\n".utf8)))
    }

    // MARK: - Scanner

    /// Whether `data` can hold anything `violations` flags; the scan reads only the files that can.
    /// Most of the package's 38 MB of sources never mention a tooltip, and `codeOnly` over all of
    /// them took 91 s of the CmuxNextAppTests run. `codeOnly` blanks characters in place and adds
    /// none, so every pattern's match is in the raw bytes as written: `toolTip` or `ToolTip` (the
    /// assignment and both AppKit calls), or `help`, then only white space (any byte that can be
    /// part of a `\s` character), then `(` or the `/` that starts a comment the scan blanks. A
    /// string literal cannot stand in that gap: its quote stays in the code the patterns read.
    static func mayHoldRawTooltip(_ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            guard let base = bytes.baseAddress else { return false }
            func find(_ needle: StaticString, from start: Int) -> Int? {
                guard start < bytes.count,
                      let hit = memmem(base + start, bytes.count - start, needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
                return base.distance(to: UnsafeRawPointer(hit))
            }
            if find("oolTip", from: 0) != nil { return true }
            var start = 0
            while let at = find("help", from: start) {
                var next = at + 4
                // ASCII white space (tab to carriage return, space) and every byte of a non-ASCII character.
                while next < bytes.count, (0x09...0x0D).contains(bytes[next]) || bytes[next] == 0x20 || bytes[next] >= 0x80 { next += 1 }
                if next < bytes.count, bytes[next] == UInt8(ascii: "(") || bytes[next] == UInt8(ascii: "/") { return true }
                start = at + 4
            }
            return false
        }
    }

    struct Violation: Equatable {
        let line: Int
        let what: String
    }

    /// The raw tooltip calls in `text` that are not allowed, with their 1-based lines.
    static func violations(in text: String) -> [Violation] {
        let code = codeOnly(text) as NSString
        let lines = text.components(separatedBy: "\n")
        var found: [Violation] = []
        func line(at location: Int) -> Int {
            code.substring(to: location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
        func allowed(_ number: Int) -> Bool {
            if hasMarker(lines[number - 1]) { return true }
            var index = number - 2
            while index >= 0, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if hasMarker(lines[index]) { return true }
                index -= 1
            }
            return false
        }
        for (pattern, what) in [(#"\.\s*help\s*\("#, "raw .help("),
                                (#"(?<![A-Za-z0-9_])(?:setToolTip|addToolTip)\s*\("#, "raw AppKit tool tip")] {
            for match in matches(pattern, in: code) {
                let number = line(at: match.range.location)
                if !allowed(number) { found.append(Violation(line: number, what: what)) }
            }
        }
        for match in matches(#"(?<![A-Za-z0-9_])toolTip\s*=(?!=)"#, in: code) {
            let number = line(at: match.range.location)
            let lineStart = code.lineRange(for: NSRange(location: match.range.location, length: 0)).location
            let prefix = code.substring(with: NSRange(location: lineStart, length: match.range.location - lineStart))
            // A local named `toolTip`, not a property.
            if prefix.range(of: #"\b(?:let|var)\s+$"#, options: .regularExpression) != nil { continue }
            if let receiver = receiver(prefix), isMenuItem(receiver, before: match.range.location, in: code) { continue }
            if !allowed(number) { found.append(Violation(line: number, what: "raw toolTip =")) }
        }
        return found.sorted { $0.line < $1.line }
    }

    static func hasMarker(_ line: String) -> Bool {
        line.range(of: #"//.*\#(marker)\s*\S"#, options: .regularExpression) != nil
    }

    static func matches(_ pattern: String, in text: NSString) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
    }

    /// The identifier before `.toolTip` (`item` in `item.toolTip =`); nil for an implicit or
    /// explicit `self`.
    static func receiver(_ prefix: String) -> String? {
        let text = prefix as NSString
        guard let match = matches(#"([A-Za-z_][A-Za-z0-9_]*)\s*[?!]?\s*\.\s*$"#, in: text).first else { return nil }
        let name = text.substring(with: match.range(at: 1))
        return name == "self" ? nil : name
    }

    /// Whether `name`'s nearest declaration before `location` (a `let`/`var` or a parameter)
    /// makes it an `NSMenuItem`.
    static func isMenuItem(_ name: String, before location: Int, in code: NSString) -> Bool {
        let head = NSString(string: code.substring(to: location))
        let pattern = #"(?:\b(?:let|var)\s+|[(,]\s*(?:_\s+)?)"# + NSRegularExpression.escapedPattern(for: name) + #"\s*[:=][^\n]*"#
        guard let last = matches(pattern, in: head).last else { return false }
        return head.substring(with: last.range).contains("NSMenuItem")
    }

    /// `text` with every comment and string literal's characters blanked to spaces (newlines kept),
    /// so the patterns see code only. Handles nested block comments, raw (`#"…"#`) and multiline
    /// strings, and code inside string interpolation.
    static func codeOnly(_ text: String) -> String {
        enum Mode {
            case code(parens: Int)
            case string(hashes: Int, multiline: Bool)
        }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var stack: [Mode] = [.code(parens: 0)]
        var index = 0
        func at(_ offset: Int) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }
        func blank(_ count: Int) {
            for _ in 0..<count where index < scalars.count {
                out.append(scalars[index] == "\n" ? "\n" : " ")
                index += 1
            }
        }
        func keep(_ count: Int) {
            for _ in 0..<count where index < scalars.count {
                out.append(scalars[index])
                index += 1
            }
        }
        func hashes(from offset: Int) -> Int {
            var count = 0
            while at(offset + count) == "#" { count += 1 }
            return count
        }
        while index < scalars.count {
            switch stack[stack.count - 1] {
            case .code(let parens):
                let scalar = scalars[index]
                if scalar == "/", at(1) == "/" {
                    while index < scalars.count, scalars[index] != "\n" { blank(1) }
                } else if scalar == "/", at(1) == "*" {
                    var depth = 0
                    repeat {
                        if at(0) == "/", at(1) == "*" {
                            depth += 1
                            blank(2)
                        } else if at(0) == "*", at(1) == "/" {
                            depth -= 1
                            blank(2)
                        } else {
                            blank(1)
                        }
                    } while depth > 0 && index < scalars.count
                } else if scalar == "#" || scalar == "\"" {
                    let count = hashes(from: 0)
                    guard at(count) == "\"" else { keep(max(count, 1)); continue }
                    let multiline = at(count + 1) == "\"" && at(count + 2) == "\""
                    keep(count + (multiline ? 3 : 1))
                    stack.append(.string(hashes: count, multiline: multiline))
                } else if scalar == "(" {
                    stack[stack.count - 1] = .code(parens: parens + 1)
                    keep(1)
                } else if scalar == ")" {
                    if parens == 0, stack.count > 1 {
                        stack.removeLast()
                    } else {
                        stack[stack.count - 1] = .code(parens: max(parens - 1, 0))
                    }
                    keep(1)
                } else {
                    keep(1)
                }
            case .string(let count, let multiline):
                let scalar = scalars[index]
                if scalar == "\\", hashes(from: 1) >= count {
                    if at(count + 1) == "(" {
                        keep(count + 2)
                        stack.append(.code(parens: 0))
                    } else {
                        blank(count + 2)
                    }
                } else if scalar == "\"", !multiline || (at(1) == "\"" && at(2) == "\""), hashes(from: multiline ? 3 : 1) >= count {
                    keep((multiline ? 3 : 1) + count)
                    stack.removeLast()
                } else if scalar == "\n", !multiline {
                    // An unterminated single-line string: never let it swallow the file.
                    stack.removeLast()
                    keep(1)
                } else {
                    blank(1)
                }
            }
        }
        return String(out)
    }
}
