import Foundation
import Testing

/// Handler lookups must carry a machine or a model identity. The remaining legacy lookups are
/// a ratchet: migrating one requires removing its allowance, and adding a new one fails this test.
@Suite struct TabLookupGuardTests {
    static let allowed: [String: [String: Int]] = [
        "AgentChatCopyHandlers.swift": ["locateTab(key)": 1, "locateTab(target.tabKey)": 1],
        "AppActionContext+TabSelection.swift": ["locateTab(id)": 1],
        "AppActionContext+Targets.swift": ["locateTab(target.id)": 1],
        "BrowserDeviceHandlers.swift": ["locateTab(tab)": 1],
        "IconMenuVisibility.swift": ["locateTab(target.id)": 1],
        "SSHTargetHandlers.swift": ["locateTab(target.id)": 1],
        "TabGroupHandlers.swift": ["locateTab($0.id)": 1],
        "TabHandlers.swift": ["locateTab(tabID)": 1, "locateTab(id)": 1],
        "TabIconHandlers.swift": ["locateTab(id)": 1],
        "WorkspaceSetVerbs.swift": ["locateTab(target.id)": 1],
    ]

    @Test func handlersDoNotAddBareTabLookups() throws {
        let root = NativeTooltipGuardTests.sources
            .appendingPathComponent("CmuxNextApp/Handlers").standardizedFileURL.path
        let enumerator = try #require(FileManager.default.enumerator(atPath: root))
        var actual: [String: [String: Int]] = [:]
        var scanned = 0
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            scanned += 1
            let source = try String(contentsOfFile: root + "/" + relative, encoding: .utf8)
            for expression in Self.bareLookups(in: source) {
                actual[relative, default: [:]][expression, default: 0] += 1
            }
        }
        #expect(scanned > 20, "found only \(scanned) handler files under \(root)")
        for file in Set(actual.keys).union(Self.allowed.keys).sorted() {
            #expect(actual[file, default: [:]] == Self.allowed[file, default: [:]], """
            \(file): bare locateTab calls changed. Pass onMachine:, model:, or surface: to new \
            calls, and remove obsolete allowances when migrating existing calls.
            Actual: \(actual[file, default: [:]])
            Allowed: \(Self.allowed[file, default: [:]])
            """)
        }
    }

    @Test func detectorUnderstandsLabelsNestingCommentsAndStrings() {
        let source = #"""
        services.locateTab(id)
        services.locateTab(
            resolve(id, fallback: old)
        )
        services.locateTab(resolve(id, onMachine: machine))
        services.locateTab(items.map { pair in pair.0 }[0])
        services.locateTab(id, onMachine: machine)
        services.locateTab(resolve(id, fallback: old),
                           /* machine scope */ onMachine: machine)
        services.locateTab(model: tab)
        services.locateTab(surface: surface)
        services.locateTab(/* nested /* comment */ */ target.id)
        // services.locateTab(commented)
        /* services.locateTab(alsoCommented) */
        let text = "services.locateTab(quoted)"
        let interpolated = "tab: \(services.locateTab(interpolatedID))"
        unrelatedlocateTab(other)
        """#
        #expect(Self.bareLookups(in: source) == [
            "locateTab(id)",
            "locateTab(resolve(id,fallback:old))",
            "locateTab(resolve(id,onMachine:machine))",
            "locateTab(items.map{pairinpair.0}[0])",
            "locateTab(target.id)",
            "locateTab(interpolatedID)",
        ])
    }

    /// Reuse the tooltip guard's Swift lexer so comments and literal contents cannot create calls.
    /// Split arguments only at the call's top level; a nested `onMachine:` is not a scope.
    static func bareLookups(in source: String) -> [String] {
        let code = NativeTooltipGuardTests.codeOnly(source) as NSString
        let openings = NativeTooltipGuardTests.matches(#"\blocateTab\s*\("#, in: code)
        var found: [String] = []
        for opening in openings {
            let start = NSMaxRange(opening.range)
            var cursor = start
            var argumentStart = start
            var nesting = 0
            var arguments: [String] = []
            while cursor < code.length {
                let character = code.character(at: cursor)
                if character == 41, nesting == 0 { // Closing parenthesis of this call.
                    arguments.append(code.substring(with: NSRange(location: argumentStart, length: cursor - argumentStart)))
                    break
                }
                if character == 44, nesting == 0 { // Top-level comma.
                    arguments.append(code.substring(with: NSRange(location: argumentStart, length: cursor - argumentStart)))
                    argumentStart = cursor + 1
                } else if character == 40 || character == 91 || character == 123 {
                    nesting += 1
                } else if character == 41 || character == 93 || character == 125 {
                    nesting -= 1
                }
                cursor += 1
            }
            guard cursor < code.length else { continue }
            let normalized = arguments.map { $0.filter { !$0.isWhitespace } }
            if normalized.first?.hasPrefix("model:") == true
                || normalized.first?.hasPrefix("surface:") == true
                || (normalized.count == 2 && normalized[1].hasPrefix("onMachine:")) { continue }
            found.append("locateTab(" + normalized.joined(separator: ",") + ")")
        }
        return found
    }
}
