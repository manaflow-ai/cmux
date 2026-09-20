import Foundation

/// The parts of an `.xcscheme` file that ``SchemeSummary`` reports.
struct XcodeSchemeFile {
    /// A `BuildableReference` element, which names a target by name and by identifier.
    struct TargetReference {
        let blueprintName: String?
        let blueprintIdentifier: String?
    }

    let name: String
    let runTarget: TargetReference?
    let testTargets: [TargetReference]
    let profileTarget: TargetReference?
    /// First build entry. Xcode archives with default settings when a scheme has
    /// no `ArchiveAction` element, so the target does not depend on one.
    let archiveTarget: TargetReference?
    let launchArguments: [String]
    let environmentVariables: [String: String]

    init(contentsOf url: URL) throws {
        let document = try XMLDocument(contentsOf: url, options: [])
        let scheme = document.rootElement()
        name = url.deletingPathExtension().lastPathComponent

        let launch = scheme?.firstChild(named: "LaunchAction")
        let runnable = launch?.firstChild(named: "BuildableProductRunnable")
            ?? launch?.firstChild(named: "RemoteRunnable")
        runTarget = runnable.flatMap(Self.targetReference(in:))

        testTargets = scheme?.firstChild(named: "TestAction")?
            .firstChild(named: "Testables")?
            .elements(forName: "TestableReference")
            .compactMap(Self.targetReference(in:)) ?? []

        profileTarget = scheme?.firstChild(named: "ProfileAction")?
            .firstChild(named: "BuildableProductRunnable")
            .flatMap(Self.targetReference(in:))

        archiveTarget = scheme?.firstChild(named: "BuildAction")?
            .firstChild(named: "BuildActionEntries")?
            .firstChild(named: "BuildActionEntry")
            .flatMap(Self.targetReference(in:))

        launchArguments = launch?.firstChild(named: "CommandLineArguments")?
            .elements(forName: "CommandLineArgument")
            .filter { $0.attribute(forName: "isEnabled")?.stringValue == "YES" }
            .compactMap { $0.attribute(forName: "argument")?.stringValue } ?? []

        var environment: [String: String] = [:]
        for variable in launch?.firstChild(named: "EnvironmentVariables")?.elements(forName: "EnvironmentVariable") ?? []
            where variable.attribute(forName: "isEnabled")?.stringValue == "YES" {
            guard let key = variable.attribute(forName: "key")?.stringValue else { continue }
            environment[key] = variable.attribute(forName: "value")?.stringValue ?? ""
        }
        environmentVariables = environment
    }

    /// Schemes in `directory`, ordered by file name.
    static func schemes(in directory: URL) -> [XcodeSchemeFile] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "xcscheme" }
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
            .compactMap { try? XcodeSchemeFile(contentsOf: $0) }
    }

    private static func targetReference(in element: XMLElement) -> TargetReference? {
        guard let reference = element.firstChild(named: "BuildableReference") else { return nil }
        return TargetReference(
            blueprintName: reference.attribute(forName: "BlueprintName")?.stringValue,
            blueprintIdentifier: reference.attribute(forName: "BlueprintIdentifier")?.stringValue
        )
    }
}

extension XMLElement {
    func firstChild(named name: String) -> XMLElement? {
        elements(forName: name).first
    }
}
