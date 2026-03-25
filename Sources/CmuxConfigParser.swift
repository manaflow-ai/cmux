import Foundation

/// Protocol for script existence checking, injectable for testing.
protocol ScriptRepositoryProtocol {
    func hasScript(named name: String) -> Bool
}

/// Parses `.cmux.yaml` project configuration files.
/// Returns a `ConfigParseResult` with best-effort parsed group and any warnings.
/// Throws `CmuxConfigError` for fatal parse errors (invalid YAML syntax).
enum CmuxConfigParser {

    /// Parse a YAML string into a workspace group definition.
    /// - Parameters:
    ///   - yaml: The raw YAML content
    ///   - projectDirectory: The project root URL (for resolving relative paths)
    ///   - scriptRepository: Optional script repo for validating script references
    /// - Returns: ConfigParseResult with the parsed group tree and warnings
    /// - Throws: CmuxConfigError.invalidYaml for fatal parse failures
    @MainActor
    static func parse(
        yaml: String,
        projectDirectory: URL,
        scriptRepository: ScriptRepositoryProtocol? = nil
    ) throws -> ConfigParseResult {
        let lines = yaml.components(separatedBy: .newlines)
        var warnings: [CmuxConfigWarning] = []

        let topLevel = try parseTopLevelMap(lines: lines)

        let name = topLevel["name"] ?? projectDirectory.lastPathComponent
        let color = topLevel["color"]

        // Parse top-level tabs
        var tabDefs: [ConfigTabDefinition] = []
        let topTabs = try parseTabsList(
            from: topLevel,
            key: "tabs",
            lines: lines,
            groupPath: [],
            scriptRepository: scriptRepository,
            warnings: &warnings
        )
        tabDefs.append(contentsOf: topTabs)

        // Parse groups (legacy groups become additional tab definitions)
        _ = try parseGroupsList(
            lines: lines,
            projectDirectory: projectDirectory,
            scriptRepository: scriptRepository,
            warnings: &warnings,
            tabDefs: &tabDefs,
            currentDepth: 1
        )

        return ConfigParseResult(
            projectName: name,
            projectColor: color,
            warnings: warnings,
            tabDefinitions: tabDefs
        )
    }

    // MARK: - Private Parsing Helpers

    /// Extracts top-level key-value pairs from simple YAML.
    private static func parseTopLevelMap(lines: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // Only parse top-level (no leading whitespace) key: value pairs
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let valueStart = trimmed.index(after: colonIdx)
            let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
            // Skip list/map values (they start with - or are empty)
            guard !value.isEmpty, !value.hasPrefix("-") else { continue }
            // Remove surrounding quotes
            result[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return result
    }

    /// Parses the `tabs:` list section from YAML lines.
    private static func parseTabsList(
        from topLevel: [String: String],
        key: String,
        lines: [String],
        groupPath: [String],
        scriptRepository: ScriptRepositoryProtocol?,
        warnings: inout [CmuxConfigWarning]
    ) throws -> [ConfigTabDefinition] {
        var defs: [ConfigTabDefinition] = []
        var inSection = false
        var sectionIndent = 0
        var entryIndent = 0
        var currentEntryLines: [String] = []

        func flushEntry() {
            guard !currentEntryLines.isEmpty else { return }
            if let tabDef = parseTabEntry(
                entryLines: currentEntryLines,
                groupPath: groupPath,
                scriptRepository: scriptRepository,
                warnings: &warnings
            ) {
                defs.append(tabDef)
            }
            currentEntryLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            if !inSection {
                if trimmed == "\(key):" || trimmed.hasPrefix("\(key):") {
                    inSection = true
                    sectionIndent = indent
                }
                continue
            }

            // We're inside the tabs section
            if indent <= sectionIndent && !trimmed.hasPrefix("-") {
                break  // Left the section
            }

            if trimmed.hasPrefix("- ") {
                flushEntry()
                currentEntryLines.append(String(trimmed.dropFirst(2)))
                entryIndent = indent
            } else if indent > entryIndent {
                // Continuation line for current entry
                currentEntryLines.append(trimmed)
            }
        }
        flushEntry()
        return defs
    }

    static func parseTabEntry(
        entryLines: [String],
        groupPath: [String],
        scriptRepository: ScriptRepositoryProtocol?,
        warnings: inout [CmuxConfigWarning]
    ) -> ConfigTabDefinition? {
        var title: String?
        var startupScript: String?

        for line in entryLines {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch key {
            case "title": title = value
            case "startupScript": startupScript = value.isEmpty ? nil : value
            default: break
            }
        }

        guard let title, !title.isEmpty else { return nil }

        if let scriptName = startupScript,
           let repo = scriptRepository,
           !repo.hasScript(named: scriptName) {
            warnings.append(.scriptNotFound(name: scriptName))
        }

        return ConfigTabDefinition(title: title, startupScript: startupScript, groupPath: groupPath)
    }

    /// Parses the `groups:` section from YAML.
    @MainActor
    private static func parseGroupsList(
        lines: [String],
        projectDirectory: URL,
        scriptRepository: ScriptRepositoryProtocol?,
        warnings: inout [CmuxConfigWarning],
        tabDefs: inout [ConfigTabDefinition],
        currentDepth: Int
    ) throws -> [String] {
        var groupNames: [String] = []
        var inGroupsSection = false
        var groupsSectionIndent = 0
        var currentGroupName: String?
        var currentGroupDir: String?
        var currentGroupLines: [String] = []

        func finalizeGroup() {
            guard let name = currentGroupName else { return }
            let groupTabs = parseGroupTabs(
                groupLines: currentGroupLines,
                groupName: name,
                scriptRepository: scriptRepository,
                warnings: &warnings
            )
            tabDefs.append(contentsOf: groupTabs)
            groupNames.append(name)
            currentGroupName = nil
            currentGroupDir = nil
            currentGroupLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            if !inGroupsSection {
                if trimmed == "groups:" {
                    inGroupsSection = true
                    groupsSectionIndent = indent
                }
                continue
            }

            if indent <= groupsSectionIndent && !trimmed.hasPrefix("-") && trimmed != "groups:" {
                finalizeGroup()
                break
            }

            if trimmed.hasPrefix("- name:") {
                finalizeGroup()
                currentGroupName = extractValue(from: trimmed, key: "- name")
            } else if trimmed.hasPrefix("workingDirectory:") {
                currentGroupDir = extractValue(from: trimmed, key: "workingDirectory")
            } else if trimmed == "groups:" && indent > groupsSectionIndent {
                if let name = currentGroupName {
                    warnings.append(.maxDepthExceeded(groupName: name))
                }
            }
            currentGroupLines.append(line)
        }
        finalizeGroup()

        return groupNames
    }

    private static func extractValue(from line: String, key: String) -> String? {
        guard let colonIdx = line.range(of: ":") else { return nil }
        let value = String(line[colonIdx.upperBound...]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func resolveWorkingDirectory(
        _ relative: String?,
        projectDirectory: URL
    ) -> URL {
        guard let relative, !relative.isEmpty else { return projectDirectory }
        let cleaned = relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
        return projectDirectory.appendingPathComponent(cleaned)
    }
}
