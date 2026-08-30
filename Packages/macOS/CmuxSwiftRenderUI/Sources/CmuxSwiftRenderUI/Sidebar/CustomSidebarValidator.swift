import CmuxSidebar
import CmuxSwiftRender
import Foundation

/// Validates custom sidebar files using the same JSON schema and Swift interpreter as rendering.
public struct CustomSidebarValidator {
    private let fileManager: FileManager
    private let fallbackDataContext: [String: SwiftValue]
    private let fallbackComparisonDataContext: [String: SwiftValue]?
    private let warningLocalizer: SidebarValidationWarningLocalizer
    private let outputInspector: RenderOutputInspector

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
        self.warningLocalizer = SidebarValidationWarningLocalizer(
            locale: warningLocale
        )
        self.outputInspector = RenderOutputInspector(
            styleResolver: RenderStyleResolver()
        )
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
                let trackedWorkspaceValue = dataContext == nil
                    && fallbackComparisonDataContext != nil
                    ? selectedWorkspaceValue(in: evaluationState)
                    : nil
                let evaluation = interpreter.evaluateWithDiagnostics(
                    program,
                    state: evaluationState,
                    trackingMemberAccessesOn: trackedWorkspaceValue
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
                let rendersVisibleContent =
                    outputInspector.containsVisibleContent(in: node)
                if !rendersVisibleContent {
                    warningMessages.append(
                        warningLocalizer.emptyRender
                    )
                }
                if dataContext == nil,
                   let comparisonContext = fallbackComparisonDataContext,
                   !evaluation.accessedTrackedMemberNames.isDisjoint(
                       with: Self.representativeChangedWorkspaceFields
                   ) {
                    let comparisonNode = interpreter.evaluate(program, state: comparisonContext)
                    if rendersVisibleContent,
                       comparisonNode.map({
                           outputInspector.containsVisibleContent(in: $0)
                       }) != true {
                        warningMessages.append(
                            warningLocalizer.emptyRenderWithoutOptionalData
                        )
                    } else if let comparisonNode,
                              outputInspector.hasSameValidationOutput(
                                  node,
                                  as: comparisonNode
                              ) {
                        warningMessages.append(
                            warningLocalizer.missingOptionalDataCoverage
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

    private static let representativeChangedWorkspaceFields =
        representativeDataContexts.changedWorkspaceFields

    private static let representativeDataContexts: (
        rich: [String: SwiftValue],
        withoutOptionalData: [String: SwiftValue],
        changedWorkspaceFields: Set<String>
    ) = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return CustomSidebarValidationContextBuilder(
            calendar: calendar
        ).representativeContexts()
    }()

    /// Creates the report entry used when a requested sidebar is absent.
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

    /// Creates a report entry for a parsed file that produced no valid view.
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

    /// Resolves the selected workspace by the context's authoritative identifier.
    private func selectedWorkspaceValue(
        in context: [String: SwiftValue]
    ) -> SwiftValue? {
        guard case let .string(selectedId)? = context["selectedId"],
              !selectedId.isEmpty,
              case let .array(workspaces)? = context["workspaces"] else {
            return nil
        }
        return workspaces.first { workspace in
            guard case let .object(fields) = workspace else { return false }
            return fields["id"] == .string(selectedId)
        }
    }

    /// Formats a decoding path for user-facing validation diagnostics.
    private func decodingPath(_ context: DecodingError.Context) -> String {
        let parts = context.codingPath.map(\.stringValue)
        return parts.isEmpty
            ? String(
                localized: "sidebar.custom.validation.rootPath",
                defaultValue: "root"
            )
            : parts.joined(separator: " › ")
    }
}
