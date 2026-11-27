import Foundation

extension BrowserImportOutcome {
    /// Localized, human-readable summary lines describing this import outcome,
    /// suitable for display in a completion dialog.
    public var formattedLines: [String] {
        var lines: [String] = []
        lines.append(
            String(
                format: String(
                    localized: "browser.import.complete.browser",
                    defaultValue: "Browser: %@"
                ),
                browserName
            )
        )

        if entries.count == 1, let entry = entries.first {
            if !entry.sourceProfileNames.isEmpty {
                lines.append(
                    String(
                        format: String(
                            localized: "browser.import.complete.sourceProfiles",
                            defaultValue: "Source profiles: %@"
                        ),
                        entry.sourceProfileNames.joined(separator: ", ")
                    )
                )
            }
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.destinationProfile",
                        defaultValue: "Destination profile: %@"
                    ),
                    entry.destinationProfileName
                )
            )
        } else if !entries.isEmpty {
            lines.append(
                String(
                    localized: "browser.import.complete.profileMappings",
                    defaultValue: "Profile mappings:"
                )
            )
            for entry in entries {
                let sourceNames = entry.sourceProfileNames.joined(separator: ", ")
                lines.append(
                    String(
                        format: String(
                            localized: "browser.import.complete.profileMapping",
                            defaultValue: "%@ -> %@"
                        ),
                        sourceNames,
                        entry.destinationProfileName
                    )
                )
            }
        }

        lines.append(
            String(
                format: String(
                    localized: "browser.import.complete.scope",
                    defaultValue: "Scope: %@"
                ),
                scope.displayName
            )
        )
        lines.append(
            String(
                format: String(
                    localized: "browser.import.complete.importedCookies",
                    defaultValue: "Imported cookies: %ld"
                ),
                totalImportedCookies
            )
        )
        if totalSkippedCookies > 0 {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.skippedCookies",
                        defaultValue: "Skipped cookies: %ld"
                    ),
                    totalSkippedCookies
                )
            )
        }
        if scope.includesHistory {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.importedHistory",
                        defaultValue: "Imported history entries: %ld"
                    ),
                    totalImportedHistoryEntries
                )
            )
        }
        if !domainFilters.isEmpty {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.domainFilter",
                        defaultValue: "Domain filter: %@"
                    ),
                    domainFilters.joined(separator: ", ")
                )
            )
        }
        if !createdDestinationProfileNames.isEmpty {
            lines.append(
                String(
                    format: String(
                        localized: "browser.import.complete.createdProfiles",
                        defaultValue: "Created cmux profiles: %@"
                    ),
                    createdDestinationProfileNames.joined(separator: ", ")
                )
            )
        }
        if !warnings.isEmpty {
            lines.append("")
            lines.append(
                String(
                    localized: "browser.import.complete.warnings",
                    defaultValue: "Warnings:"
                )
            )
            for warning in warnings {
                lines.append("- \(warning)")
            }
        }

        return lines
    }
}
