import CMUXProjectModel
import Foundation

/// Manual verification entrypoint for ``XcodeProjectAdapter``.
///
/// Usage:
///
///     swift run cmux-project-dump <path to .xcworkspace or .xcodeproj> [--full]
///
/// Prints a hierarchical summary of the parsed ``ProjectModel`` so changes to
/// the adapter can be eyeballed against a real project without standing up the
/// SwiftUI navigator pane. `--full` prints every field of the model in a stable
/// order, so two adapter revisions can be compared with `diff`.

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
        if arguments.contains("--full") {
            printFullModel(model)
        } else {
            printModel(model)
        }
    }

    private static func printFullModel(_ model: ProjectModel) {
        print("model id=\(model.id.rawValue) name=\(model.displayName) root=\(model.rootURL.path) adapter=\(model.adapter.rawValue)")
        for module in model.modules {
            print("module id=\(module.id.rawValue) name=\(module.displayName) root=\(module.rootURL.path)")
            for target in module.targets {
                print("  target id=\(target.id.rawValue) name=\(target.displayName) type=\(target.productType.rawValue) platforms=\(target.platforms) bundle=\(target.bundleIdentifier ?? "-") deploy=\(target.deploymentTarget ?? "-") deps=\(target.dependencies.map(\.rawValue))")
            }
            for config in module.configurations {
                let scope: String
                switch config.scope {
                case .project: scope = "project"
                case let .target(id): scope = "target:\(id.rawValue)"
                }
                print("  config id=\(config.id.rawValue) name=\(config.name) scope=\(scope) base=\(config.baseConfigurationPath?.path ?? "-")")
                for key in config.rawSettings.keys.sorted() {
                    print("    \(key)=\(config.rawSettings[key] ?? "")")
                }
            }
            for scheme in module.schemes {
                print("  scheme id=\(scheme.id.rawValue) shared=\(scheme.isShared) run=\(scheme.runTargetIDs.map(\.rawValue)) test=\(scheme.testTargetIDs.map(\.rawValue)) profile=\(scheme.profileTargetID?.rawValue ?? "-") archive=\(scheme.archiveTargetID?.rawValue ?? "-") args=\(scheme.launchArguments)")
                for key in scheme.environmentVariables.keys.sorted() {
                    print("    env \(key)=\(scheme.environmentVariables[key] ?? "")")
                }
            }
            printFullNode(.group(module.rootGroup), indent: "  ")
        }
    }

    private static func printFullNode(_ node: ProjectNodeKind, indent: String) {
        switch node {
        case let .group(group):
            print("\(indent)group id=\(group.id.rawValue) name=\(group.displayName) style=\(group.style.rawValue) path=\(group.resolvedPath?.path ?? "-")")
            for child in group.children {
                printFullNode(child, indent: indent + "  ")
            }
        case let .file(file):
            let members = file.memberships.map { "\($0.targetID.rawValue):\($0.role.rawValue):\($0.compilerFlags)" }
            print("\(indent)file id=\(file.id.rawValue) name=\(file.displayName) type=\(file.fileType ?? "-") exists=\(file.existsOnDisk) path=\(file.resolvedPath?.path ?? "-") members=\(members)")
        }
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
