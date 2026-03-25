import Foundation

/// Group and tab-within-group parsing helpers for CmuxConfigParser.
extension CmuxConfigParser {

    /// Extract tabs from lines belonging to a single group entry.
    static func parseGroupTabs(
        groupLines: [String],
        groupName: String,
        scriptRepository: ScriptRepositoryProtocol?,
        warnings: inout [CmuxConfigWarning]
    ) -> [ConfigTabDefinition] {
        var defs: [ConfigTabDefinition] = []
        var inTabs = false
        var tabsSectionIndent = 0
        var entryIndent = 0
        var currentEntryLines: [String] = []

        func flushEntry() {
            guard !currentEntryLines.isEmpty else { return }
            if let tabDef = parseTabEntry(
                entryLines: currentEntryLines,
                groupPath: [groupName],
                scriptRepository: scriptRepository,
                warnings: &warnings
            ) {
                defs.append(tabDef)
            }
            currentEntryLines = []
        }

        for line in groupLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count

            if !inTabs {
                if trimmed == "tabs:" {
                    inTabs = true
                    tabsSectionIndent = indent
                }
                continue
            }

            if indent <= tabsSectionIndent && !trimmed.hasPrefix("-") {
                break
            }

            if trimmed.hasPrefix("- ") {
                flushEntry()
                currentEntryLines.append(String(trimmed.dropFirst(2)))
                entryIndent = indent
            } else if indent > entryIndent {
                currentEntryLines.append(trimmed)
            }
        }
        flushEntry()
        return defs
    }
}
