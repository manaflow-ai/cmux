import CMUXProjectModel
import Foundation

/// Manual verification entrypoint for ``XcodeProjectAdapter``.
///
/// Usage:
///
///     swift run cmux-project-dump <path to .xcworkspace or .xcodeproj>
///
/// Prints a hierarchical summary of the parsed ``ProjectModel`` so changes to
/// the adapter can be eyeballed against a real project without standing up the
/// SwiftUI navigator pane.

@main
struct CMUXProjectDump {
    static func main() {
        var arguments = CommandLine.arguments.dropFirst()
        let rawPath = arguments.popFirst() ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: rawPath, isDirectory: false).standardizedFileURL

        let adapter = XcodeProjectAdapter()
        let model: ProjectModel
        do {
            model = try adapter.load(at: url)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
        printModel(model)
    }

    private static func printModel(_ model: ProjectModel) {
        print("Project: \(model.displayName)  [\(model.adapter.rawValue)]")
        print("  root: \(model.rootURL.path)")
        print("  modules: \(model.modules.count)")
        for module in model.modules {
            print("  - module: \(module.displayName)")
            print("      root: \(module.rootURL.path)")
            print("      targets: \(module.targets.count)")
            for target in module.targets {
                print("        - \(target.displayName) [\(target.productType.rawValue)] platforms=\(target.platforms.joined(separator: ",")) bundle=\(target.bundleIdentifier ?? "-") deploy=\(target.deploymentTarget ?? "-") deps=\(target.dependencies.count)")
            }
            print("      tree:")
            printNode(.group(module.rootGroup), indent: "        ")
        }
    }

    private static func printNode(_ node: ProjectNodeKind, indent: String) {
        switch node {
        case let .group(group):
            let style = group.style.rawValue
            print("\(indent)\u{1F4C1} \(group.displayName)  [\(style)]")
            for child in group.children {
                printNode(child, indent: indent + "  ")
            }
        case let .file(file):
            let warn = file.existsOnDisk ? "" : " (missing)"
            let members = file.memberships.isEmpty
                ? ""
                : "  targets=\(file.memberships.map { $0.targetID.rawValue.prefix(8) }.joined(separator: ","))"
            print("\(indent)\u{1F4C4} \(file.displayName)\(warn)\(members)")
        }
    }
}
