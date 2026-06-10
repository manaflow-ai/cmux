import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - Sidebar command option parsing and mutation scheduling
extension TerminalController {
    nonisolated static func tokenizeArgs(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    cursor = trimmed.index(after: cursor)
                    continue
                }
                if char == "\\" {
                    let nextIndex = trimmed.index(after: cursor)
                    if nextIndex < trimmed.endIndex {
                        let next = trimmed[nextIndex]
                        switch next {
                        case "n":
                            current.append("\n")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "r":
                            current.append("\r")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "t":
                            current.append("\t")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "\"", "'", "\\":
                            current.append(next)
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        default:
                            break
                        }
                    }
                }
                current.append(char)
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = true
                quoteChar = char
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            current.append(char)
            cursor = trimmed.index(after: cursor)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    func parseOptions(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = Self.tokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                stopParsingOptions = true
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    func parseOptionsNoStop(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = Self.tokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "--" {
                i += 1
                continue
            }
            if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    func resolveTabForReport(_ args: String) -> Tab? {
        let parsed = parseOptions(args)
        if let tabArg = parsed.options["tab"], !tabArg.isEmpty {
            // First try the local tabManager if available
            if let tabManager = self.tabManager,
               let tab = resolveTab(from: tabArg, tabManager: tabManager) {
                return tab
            }
            // The tab may belong to a different window — search all contexts.
            if let uuid = UUID(uuidString: tabArg.trimmingCharacters(in: .whitespacesAndNewlines)),
               let otherManager = AppDelegate.shared?.tabManagerFor(tabId: uuid) {
                return otherManager.tabs.first(where: { $0.id == uuid })
            }
            return nil
        }
        // Only require self.tabManager when using the selected tab (no --tab arg)
        guard let tabManager = self.tabManager else { return nil }
        guard let selectedId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == selectedId })
    }

    enum SidebarMutationTabTarget {
        case selected
        case workspace(UUID)
        case index(Int)
    }

    func parseSidebarMutationTabTarget(
        options: [String: String]
    ) -> (target: SidebarMutationTabTarget?, error: String?) {
        if let rawTabArg = options["tab"] {
            let tabArg = rawTabArg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tabArg.isEmpty else {
                return (nil, "ERROR: Tab not found")
            }
            if let tabId = UUID(uuidString: tabArg) {
                return (.workspace(tabId), nil)
            }
            if let index = Int(tabArg), index >= 0 {
                return (.index(index), nil)
            }
            return (nil, "ERROR: Tab not found")
        }
        return (.selected, nil)
    }

    func resolveSidebarMutationTab(_ target: SidebarMutationTabTarget) -> Tab? {
        switch target {
        case .selected:
            guard let tabManager = self.tabManager,
                  let selectedId = tabManager.selectedTabId else {
                return nil
            }
            return tabManager.tabs.first(where: { $0.id == selectedId })
        case .workspace(let tabId):
            return tabForSidebarMutation(id: tabId)
        case .index(let index):
            guard let tabManager = self.tabManager,
                  index < tabManager.tabs.count else {
                return nil
            }
            return tabManager.tabs[index]
        }
    }

    func tabForSidebarMutation(id: UUID) -> Tab? {
        if let tab = tabManager?.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let otherManager = AppDelegate.shared?.tabManagerFor(tabId: id) {
            return otherManager.tabs.first(where: { $0.id == id })
        }
        return nil
    }

    func parseSidebarMetadataFormat(_ raw: String) -> SidebarMetadataFormat? {
        switch raw.lowercased() {
        case "plain":
            return .plain
        case "markdown", "md":
            return .markdown
        default:
            return nil
        }
    }

    func normalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func parseOptionalPanelIdOption(
        options: [String: String],
        usage: String
    ) -> (panelId: UUID?, error: String?) {
        guard let rawPanelArg = options["panel"] ?? options["surface"] else {
            return (nil, nil)
        }
        let panelArg = rawPanelArg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else {
            return (nil, "ERROR: Missing panel id — usage: \(usage)")
        }
        guard let panelId = UUID(uuidString: panelArg) else {
            return (nil, "ERROR: Invalid panel id '\(rawPanelArg)'")
        }
        return (panelId, nil)
    }

    func scheduleSidebarMutation(
        target: SidebarMutationTabTarget,
        mutation: @escaping (TerminalController, Tab) -> Void
    ) {
        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self, let tab = self.resolveSidebarMutationTab(target) else { return }
            mutation(self, tab)
        }
    }

    func schedulePanelMetadataMutation(
        args: String,
        options: [String: String],
        missingPanelUsage: String,
        mutation: @escaping (Tab, UUID) -> Void
    ) -> String {
        let rawPanelArg = options["panel"] ?? options["surface"]
        let surfaceIdFromOptions: UUID?
        if let rawPanelArg {
            if rawPanelArg.isEmpty {
                return "ERROR: Missing panel id — usage: \(missingPanelUsage)"
            }
            guard let surfaceId = UUID(uuidString: rawPanelArg) else {
                return "ERROR: Invalid panel id '\(rawPanelArg)'"
            }
            surfaceIdFromOptions = surfaceId
        } else {
            surfaceIdFromOptions = nil
        }

        if let tabArg = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tabArg.isEmpty,
           UUID(uuidString: tabArg) == nil,
           Int(tabArg) == nil {
            return "ERROR: Tab not found"
        }

        if let scope = Self.explicitSocketScope(options: options) {
            TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
                guard let self,
                      let tab = self.tabForSidebarMutation(id: scope.workspaceId) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                mutation(tab, scope.panelId)
            }
            return "OK"
        }

        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self,
                  let tab = self.resolveTabForReport(args) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard let surfaceId = surfaceIdFromOptions ?? tab.focusedPanelId else { return }
            guard validSurfaceIds.contains(surfaceId) else { return }
            mutation(tab, surfaceId)
        }
        return "OK"
    }

}
