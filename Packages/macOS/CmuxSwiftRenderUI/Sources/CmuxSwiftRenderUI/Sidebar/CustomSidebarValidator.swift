import CmuxSidebar
import CmuxSwiftRender
import Foundation

/// Validates custom sidebar files using the same JSON schema and Swift interpreter as rendering.
public struct CustomSidebarValidator {
    private let fileManager: FileManager
    private let fallbackDataContext: [String: SwiftValue]
    private let fallbackComparisonDataContext: [String: SwiftValue]?
    private let warningLocale: Locale

    /// Creates a validator with injectable filesystem and data-context dependencies.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem client used for discovery and source reads.
    ///   - fallbackDataContext: Optional caller-provided validation state. Pass
    ///     `nil` to use the runtime-shaped representative contexts and enable
    ///     optional-data coverage validation.
    ///   - warningLocale: Locale used to resolve validation warning text.
    public init(
        fileManager: FileManager = .default,
        fallbackDataContext: [String: SwiftValue]? = nil,
        warningLocale: Locale = .current
    ) {
        self.fileManager = fileManager
        self.fallbackDataContext = fallbackDataContext ?? Self.defaultDataContext
        self.fallbackComparisonDataContext = fallbackDataContext == nil
            ? Self.defaultComparisonDataContext
            : nil
        self.warningLocale = warningLocale
    }

    /// Discovers custom sidebar source files in a directory.
    ///
    /// Swift files are preferred over JSON files with the same base name.
    public func discover(in directory: URL, name requestedName: String? = nil) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var fileByName: [String: URL] = [:]
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == "swift" || ext == "json" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if let requestedName, requestedName != name { continue }
            if fileByName[name]?.pathExtension.lowercased() == "swift" { continue }
            fileByName[name] = url
        }

        return fileByName.keys.sorted().compactMap { fileByName[$0] }
    }

    /// Validates every discovered sidebar, or one requested sidebar name.
    public func validate(
        directory: URL,
        name requestedName: String? = nil,
        dataContext: [String: SwiftValue]? = nil
    ) -> CustomSidebarValidationReport {
        let urls = discover(in: directory, name: requestedName)
        if let requestedName, urls.isEmpty {
            return CustomSidebarValidationReport(entries: [
                missingEntry(name: requestedName, directory: directory)
            ])
        }
        let entries = urls.map { validate(fileURL: $0, dataContext: dataContext) }
        return CustomSidebarValidationReport(entries: entries)
    }

    /// Validates a specific sidebar file URL.
    public func validate(
        fileURL: URL,
        dataContext: [String: SwiftValue]? = nil
    ) -> CustomSidebarValidationEntry {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let kind: CustomSidebarFileKind = ext == "swift" ? .swift : .json

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: String(localized: "sidebar.custom.validation.fileMissing", defaultValue: "Sidebar file is missing.")
            )
        }

        do {
            var warningMessages: [String] = []
            switch kind {
            case .swift:
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let interpreter = SwiftViewInterpreter()
                let program = interpreter.parse(source)
                let evaluationState = dataContext ?? fallbackDataContext
                let trackedWorkspaceValues = dataContext == nil && fallbackComparisonDataContext != nil
                    ? workspaceValues(in: evaluationState).first.map { [$0] } ?? []
                    : []
                let evaluation = interpreter.evaluateWithDiagnostics(
                    program,
                    state: evaluationState,
                    trackingMemberAccessesOn: trackedWorkspaceValues
                )
                guard let node = evaluation.node else {
                    return invalidEntry(
                        name: name,
                        fileURL: fileURL,
                        kind: kind,
                        message: String(
                            localized: "sidebar.custom.noView",
                            defaultValue: "No supported SwiftUI view found."
                        )
                    )
                }
                let rendersVisibleContent = node.containsVisibleContent
                if !rendersVisibleContent {
                    warningMessages.append(
                        localizedEmptySidebarRenderWarning(locale: warningLocale)
                    )
                }
                if dataContext == nil,
                   let comparisonContext = fallbackComparisonDataContext,
                   !evaluation.accessedTrackedMemberNames.isDisjoint(
                       with: Self.representativeOptionalWorkspaceFields
                   ) {
                    let comparisonNode = interpreter.evaluate(program, state: comparisonContext)
                    if rendersVisibleContent,
                       comparisonNode?.containsVisibleContent != true {
                        warningMessages.append(
                            localizedEmptySidebarRenderWithoutOptionalDataWarning(
                                locale: warningLocale
                            )
                        )
                    } else if let comparisonNode,
                              node.hasSameValidationOutput(as: comparisonNode) {
                        warningMessages.append(
                            localizedMissingOptionalDataCoverageWarning(
                                locale: warningLocale
                            )
                        )
                    }
                }
            case .json:
                let data = try Data(contentsOf: fileURL)
                _ = try JSONDecoder().decode(DSLDocument.self, from: data)
            }
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: nil,
                warningMessages: warningMessages
            )
        } catch {
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: describe(error)
            )
        }
    }

    /// Converts decoding and filesystem errors into sidebar-facing text.
    public func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case let .keyNotFound(key, ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.missingKey", defaultValue: "Missing key '%@' at %@"),
                    key.stringValue,
                    decodingPath(ctx)
                )
            case let .typeMismatch(_, ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.typeMismatch", defaultValue: "Type mismatch at %@"),
                    decodingPath(ctx)
                )
            case let .valueNotFound(_, ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.missingValue", defaultValue: "Missing value at %@"),
                    decodingPath(ctx)
                )
            case let .dataCorrupted(ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.invalidJSON", defaultValue: "Invalid JSON at %@"),
                    decodingPath(ctx)
                )
            @unknown default:
                return String(localized: "sidebar.custom.validation.decodeFailed", defaultValue: "Failed to decode sidebar JSON.")
            }
        }
        return String(localized: "sidebar.custom.validation.readFailed", defaultValue: "Failed to read sidebar file.")
    }

    /// Representative runtime-shaped data used to validate Swift sidebars
    /// outside a live render.
    ///
    /// The context is produced by ``CustomSidebarDataContextBuilder`` from one
    /// workspace with every optional value populated and one with those values
    /// absent, so validation exercises the same types and omission rules as a
    /// live sidebar.
    public static let defaultDataContext: [String: SwiftValue] = representativeDataContexts.rich

    private static let defaultComparisonDataContext = representativeDataContexts.withoutOptionalData

    private static let representativeOptionalWorkspaceFields: Set<String> = {
        let richFields = firstWorkspaceFields(in: representativeDataContexts.rich)
        let comparisonFields = firstWorkspaceFields(in: representativeDataContexts.withoutOptionalData)
        return Set(richFields.keys).subtracting(comparisonFields.keys)
    }()

    private static let representativeDataContexts: (
        rich: [String: SwiftValue],
        withoutOptionalData: [String: SwiftValue]
    ) = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let builder = CustomSidebarDataContextBuilder(calendar: calendar)
        let richWorkspace = makeRepresentativeSelectedWorkspace(includingOptionalData: true)
        let comparisonWorkspace = makeRepresentativeSelectedWorkspace(includingOptionalData: false)
        let sparseWorkspace = makeRepresentativeSparseWorkspace()
        return (
            rich: builder.dataContext(
                for: makeRepresentativeSnapshot(workspaces: [richWorkspace, sparseWorkspace])
            ),
            withoutOptionalData: builder.dataContext(
                for: makeRepresentativeSnapshot(workspaces: [comparisonWorkspace, sparseWorkspace])
            )
        )
    }()

    private func missingEntry(name: String, directory: URL) -> CustomSidebarValidationEntry {
        let swiftURL = directory.appendingPathComponent("\(name).swift")
        let jsonURL = directory.appendingPathComponent("\(name).json")
        let missingURL = fileManager.fileExists(atPath: swiftURL.path) ? swiftURL : jsonURL
        return CustomSidebarValidationEntry(
            name: name,
            fileURL: missingURL,
            kind: missingURL.pathExtension.lowercased() == "swift" ? .swift : .json,
            errorMessage: String(localized: "sidebar.custom.validation.fileMissing", defaultValue: "Sidebar file is missing.")
        )
    }

    private func invalidEntry(
        name: String,
        fileURL: URL,
        kind: CustomSidebarFileKind,
        message: String
    ) -> CustomSidebarValidationEntry {
        CustomSidebarValidationEntry(
            name: name,
            fileURL: fileURL,
            kind: kind,
            errorMessage: message
        )
    }
}

func localizedEmptySidebarRenderWarning(locale: Locale = .current) -> String {
    if let localized = localizedSidebarValidationWarning(
        key: "sidebar.custom.validation.emptyRender",
        locale: locale
    ) {
        return localized
    }
    return String(
        localized: LocalizedStringResource(
            "sidebar.custom.validation.emptyRender",
            defaultValue: "Sidebar rendered no visible content.",
            locale: locale,
            bundle: .module
        )
    )
}

func localizedEmptySidebarRenderWithoutOptionalDataWarning(
    locale: Locale = .current
) -> String {
    if let localized = localizedSidebarValidationWarning(
        key: "sidebar.custom.validation.emptyRenderWithoutOptionalData",
        locale: locale
    ) {
        return localized
    }
    return String(
        localized: LocalizedStringResource(
            "sidebar.custom.validation.emptyRenderWithoutOptionalData",
            defaultValue: "Sidebar rendered no visible content when optional workspace data was absent.",
            locale: locale,
            bundle: .module
        )
    )
}

func localizedMissingOptionalDataCoverageWarning(locale: Locale = .current) -> String {
    if let localized = localizedSidebarValidationWarning(
        key: "sidebar.custom.validation.noOptionalDataCoverage",
        locale: locale
    ) {
        return localized
    }
    return String(
        localized: LocalizedStringResource(
            "sidebar.custom.validation.noOptionalDataCoverage",
            defaultValue: "Sidebar output did not change when its referenced optional workspace data was removed.",
            locale: locale,
            bundle: .module
        )
    )
}

/// Resolves a package-owned warning for an explicit locale.
///
/// Xcode app builds provide compiled language tables. SwiftPM's command-line
/// build instead copies the string catalog into the resource bundle verbatim,
/// so fall back to reading that packaged catalog without introducing a second
/// translation source.
private func localizedSidebarValidationWarning(
    key: String,
    locale: Locale
) -> String? {
    let availableLocalizations = Bundle.module.localizations.filter { $0 != "Base" }
    let preferredLocalizations = Bundle.preferredLocalizations(
        from: availableLocalizations,
        forPreferences: [locale.identifier]
    )
    for localization in preferredLocalizations {
        guard
            let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
            let languageBundle = Bundle(path: path)
        else { continue }
        let localized = languageBundle.localizedString(
            forKey: key,
            value: nil,
            table: nil
        )
        if localized != key {
            return localized
        }
    }
    return packagedSidebarValidationStringCatalog?.localizedString(
        forKey: key,
        locale: locale
    )
}

private struct SidebarValidationStringCatalog: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct Localization: Decodable, Sendable {
            struct StringUnit: Decodable, Sendable {
                let value: String
            }

            let stringUnit: StringUnit?
        }

        let localizations: [String: Localization]?
    }

    let strings: [String: Entry]

    func localizedString(forKey key: String, locale: Locale) -> String? {
        guard let localizations = strings[key]?.localizations else { return nil }
        let preferredLocalizations = Bundle.preferredLocalizations(
            from: localizations.keys.sorted(),
            forPreferences: [locale.identifier]
        )
        guard let localization = preferredLocalizations.first else { return nil }
        return localizations[localization]?.stringUnit?.value
    }
}

private let packagedSidebarValidationStringCatalog: SidebarValidationStringCatalog? = {
    guard
        let url = Bundle.module.url(
            forResource: "Localizable",
            withExtension: "xcstrings"
        ),
        let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(SidebarValidationStringCatalog.self, from: data)
}()

private func makeRepresentativeSelectedWorkspace(
    includingOptionalData: Bool
) -> CustomSidebarWorkspaceSnapshot {
    let pullRequest: SwiftValue = .object([
        "number": .int(412),
        "label": .string("PR #412"),
        "url": .string("https://github.com/manaflow-ai/cmux/pull/412"),
        "status": .string("open"),
        "stale": .bool(false),
        "branch": .string("fix/checkout"),
    ])
    return CustomSidebarWorkspaceSnapshot(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x12)),
        title: "checkout-flow",
        isSelected: true,
        isPinned: false,
        index: 0,
        directory: "/Users/cmux/checkout-flow",
        listeningPorts: [3000],
        unreadCount: 3,
        surfaces: [
            CustomSidebarSurfaceSnapshot(
                panelId: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x14)),
                title: "Tests",
                isFocused: true,
                isPinned: false,
                directory: "/Users/cmux/checkout-flow",
                gitBranch: "fix/checkout",
                gitIsDirty: false,
                listeningPorts: [3000]
            ),
        ],
        surfaceCount: 1,
        customDescription: includingOptionalData ? "Checkout work" : nil,
        customColor: includingOptionalData ? "#7AA2F7" : nil,
        gitBranch: includingOptionalData ? "fix/checkout" : nil,
        gitIsDirty: false,
        pullRequestValues: includingOptionalData ? [pullRequest] : [],
        progress: includingOptionalData ? .init(value: 0.41, label: "Tests running") : nil,
        latestConversationMessage: includingOptionalData ? "Waiting for review" : nil,
        latestSubmittedMessage: includingOptionalData ? "Finish checkout coverage" : nil,
        latestSubmittedAt: includingOptionalData
            ? Date(timeIntervalSince1970: 1_779_999_400)
            : nil,
        remote: includingOptionalData
            ? .init(target: "aws-m4pro-1", stateRawValue: "connected", isConnected: true)
            : nil
    )
}

private func makeRepresentativeSparseWorkspace() -> CustomSidebarWorkspaceSnapshot {
    CustomSidebarWorkspaceSnapshot(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x13)),
        title: "notes",
        isSelected: false,
        isPinned: false,
        index: 1,
        directory: "/Users/cmux/notes",
        listeningPorts: [],
        unreadCount: 0,
        surfaces: [],
        surfaceCount: 0,
        customDescription: nil,
        customColor: nil,
        gitBranch: nil,
        gitIsDirty: false,
        pullRequestValues: [],
        progress: nil,
        latestConversationMessage: nil,
        latestSubmittedMessage: nil,
        latestSubmittedAt: nil,
        remote: nil
    )
}

private func makeRepresentativeSnapshot(
    workspaces: [CustomSidebarWorkspaceSnapshot]
) -> CustomSidebarContextSnapshot {
    let selectedId = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x12))
    return CustomSidebarContextSnapshot(
        workspaces: workspaces,
        selectedWorkspaceId: selectedId,
        selectedWorkspaceTitle: "checkout-flow",
        totalUnreadCount: 3,
        now: Date(timeIntervalSince1970: 1_780_000_000)
    )
}

private func workspaceValues(in context: [String: SwiftValue]) -> [SwiftValue] {
    guard case let .array(workspaces)? = context["workspaces"] else { return [] }
    return workspaces
}

private func firstWorkspaceFields(
    in context: [String: SwiftValue]
) -> [String: SwiftValue] {
    guard case let .object(fields)? = workspaceValues(in: context).first else {
        return [:]
    }
    return fields
}

private func decodingPath(_ ctx: DecodingError.Context) -> String {
    let parts = ctx.codingPath.map(\.stringValue)
    return parts.isEmpty ? String(localized: "sidebar.custom.validation.rootPath", defaultValue: "root") : parts.joined(separator: " › ")
}
