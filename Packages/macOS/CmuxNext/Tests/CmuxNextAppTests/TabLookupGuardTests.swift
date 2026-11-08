import Foundation
import Testing

/// Handler lookups must carry a machine or a model identity. Legacy any-machine lookups anywhere
/// in the app are a ratchet: migrating one removes its allowance; adding a new one fails this test.
@Suite struct TabLookupGuardTests {
    static let allowed: [String: [String: Int]] = [
        "AgentChatCopyHandlers.swift": ["locateTab(key)": 1, "locateTab(target.tabKey)": 1],
        // `AppActionContext.targetTab(_:_:)`: the unscoped fallback when an invocation names no machine.
        "AppActionContext+Targets.swift": ["locateTab(id)": 1],
        "BrowserDeviceHandlers.swift": ["locateTab(tab)": 1],
        "TabHandlers.swift": ["locateTab(tabID)": 1],
    ]

    // Paths are relative to Sources/CmuxNextApp; this legacy allowance only shrinks.
    static let legacyAllowed: [String: [String: Int]] = [
        "AgentCursor/AgentCursorSnapshotBuilder.swift": ["locateTabOnAnyMachine(id)": 1],
        "AgentTabs+Wiring.swift": ["locateTabOnAnyMachine($0)": 1, "locateTabOnAnyMachine(chat)": 4, "locateTabOnAnyMachine(key)": 15],
        "AppServices+Hibernation.swift": ["locateTabOnAnyMachine(key)": 1],
        "AppServices+Incognito.swift": ["locateTabOnAnyMachine(key)": 1],
        "AppServices+WorkContext.swift": ["locateTabOnAnyMachine(tab)": 1],
        "Bookmarks/BookmarkOpener.swift": ["locateTabOnAnyMachine(key)": 1],
        "BrowserHost/AppDevToolsRelay.swift": ["locateTabOnAnyMachine(key)": 1, "locateTabOnAnyMachine(targetID)": 1],
        "BrowserPageRequests.swift": ["locateTabOnAnyMachine(key)": 2],
        "Control/AppBrowserPage.swift": ["locateTabOnAnyMachine(tabID)": 1],
        "Control/AppBrowserPasskeyHost.swift": ["locateTabOnAnyMachine(tabID)": 3],
        "DeepLinks/DurableTabLink.swift": ["locateTabOnAnyMachine(id)": 1],
        "DesignMode/BrowserDesignModeController.swift": ["locateTabOnAnyMachine(key)": 1],
        "Hibernation/AgentPageHibernation.swift": ["locateTabOnAnyMachine(key)": 1],
        "Home/HomeLinkPreviewProvider.swift": ["locateTabOnAnyMachine($0)": 1, "locateTabOnAnyMachine(id)": 1, "locateTabOnAnyMachine(key)": 2, "locateTabOnAnyMachine(tabID)": 1],
        "Links/LinkOpener.swift": ["locateTabOnAnyMachine(key)": 1],
        "Notifications/HandoffNotices.swift": ["locateTabOnAnyMachine($0)": 1],
        "PaletteSourcesBridge.swift": ["locateTabOnAnyMachine(id)": 2],
        "SidebarBridge+PinnedItems.swift": ["locateTabOnAnyMachine(ref)": 1],
        "TabSearch/AppServices+RevealTab.swift": ["locateTabOnAnyMachine(id)": 1],
        "TerminalHooks.swift": ["locateTabOnAnyMachine(key)": 1],
        "Usage/AppResourceSource.swift": ["locateTabOnAnyMachine(id)": 1],
        "Usage/ResourceControl.swift": ["locateTabOnAnyMachine(tab)": 1],
        "Vault/AgentHistorySource.swift": ["locateTabOnAnyMachine(tab)": 1],
    ]

    @Test(arguments: ["locateTab", "locateTabOnAnyMachine"])
    func tabLookupsDoNotBroadenMigrationDebt(_ name: String) throws {
        let handlerOnly = name == "locateTab"
        let allowed = handlerOnly ? Self.allowed : Self.legacyAllowed
        let root = NativeTooltipGuardTests.sources
            .appendingPathComponent(handlerOnly ? "CmuxNextApp/Handlers" : "CmuxNextApp")
            .standardizedFileURL.path
        let enumerator = try #require(FileManager.default.enumerator(atPath: root))
        var actual: [String: [String: Int]] = [:]
        var scanned = 0
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            scanned += 1
            let source = try String(contentsOfFile: root + "/" + relative, encoding: .utf8)
            for expression in Self.bareLookups(in: source, named: name) {
                actual[relative, default: [:]][expression, default: 0] += 1
            }
        }
        #expect(scanned > 20, "found only \(scanned) Swift files under \(root)")
        for file in Set(actual.keys).union(allowed.keys).sorted() {
            #expect(actual[file, default: [:]] == allowed[file, default: [:]], """
            \(file): \(name) calls changed. Pass onMachine:, model:, or surface: to new locateTab \
            calls, and remove obsolete allowances when migrating existing calls.
            Actual: \(actual[file, default: [:]])
            Allowed: \(allowed[file, default: [:]])
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
        services.locateTabOnAnyMachine(legacyID)
        services.locateTabOnAnyMachine(resolve(id, fallback: old))
        // services.locateTabOnAnyMachine(commented)
        let legacyText = "services.locateTabOnAnyMachine(quoted)"
        func locateTabOnAnyMachine(_ id: String) {}
        """#
        #expect(Self.bareLookups(in: source) == [
            "locateTab(id)",
            "locateTab(resolve(id,fallback:old))",
            "locateTab(resolve(id,onMachine:machine))",
            "locateTab(items.map{pairinpair.0}[0])",
            "locateTab(target.id)",
            "locateTab(interpolatedID)",
        ])
        #expect(Self.bareLookups(in: source, named: "locateTabOnAnyMachine") == [
            "locateTabOnAnyMachine(legacyID)",
            "locateTabOnAnyMachine(resolve(id,fallback:old))",
        ])
    }

    /// Reuse the tooltip guard's Swift lexer so comments and literal contents cannot create calls.
    /// Split arguments only at the call's top level; a nested `onMachine:` is not a scope.
    static func bareLookups(in source: String, named name: String = "locateTab") -> [String] {
        let code = NativeTooltipGuardTests.codeOnly(source) as NSString
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\("#
        let openings = NativeTooltipGuardTests.matches(pattern, in: code)
        var found: [String] = []
        for opening in openings {
            let prefix = code.substring(to: opening.range.location)
            if prefix.range(of: #"\bfunc\s*$"#, options: .regularExpression) != nil { continue }
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
            if name == "locateTab", normalized.first?.hasPrefix("model:") == true
                || normalized.first?.hasPrefix("surface:") == true
                || (normalized.count == 2 && normalized[1].hasPrefix("onMachine:")) { continue }
            found.append(name + "(" + normalized.joined(separator: ",") + ")")
        }
        return found
    }
}
