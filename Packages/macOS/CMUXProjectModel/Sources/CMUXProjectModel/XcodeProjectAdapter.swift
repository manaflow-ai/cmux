import Foundation
import PathKit
import XcodeProj

/// ``ProjectAdapter`` implementation backed by tuist/XcodeProj.
///
/// Parses a `.xcworkspace` or `.xcodeproj` URL into a ``ProjectModel`` whose
/// modules, navigator groups, files, target memberships, and target summaries
/// match what Xcode shows in its Project Navigator and Targets list. The
/// adapter is read-only and intentionally avoids running `xcodebuild` so that
/// loading a project is fast (~3-30 ms on cmux's own project) and side-effect
/// free.
///
/// Use cases the adapter does **not** cover yet, and that callers should
/// degrade gracefully on:
///
/// - Cross-project dependencies (`PBXContainerItemProxy` with a non-local
///   `containerPortal`) are recorded as missing dependencies rather than
///   followed.
/// - Xcode 16+ `PBXFileSystemSynchronizedRootGroup` is rendered as a single
///   folder node and the adapter walks the on-disk directory to enumerate
///   children; per-target membership exception sets are not yet applied.
/// - Build settings, schemes, and `.xcconfig` resolution are deliberately
///   out of scope for this adapter; later additions to ``ProjectModel`` will
///   surface them through additional types populated by separate code paths.
public struct XcodeProjectAdapter: ProjectAdapter, Sendable {
    public let kind: ProjectAdapterKind = .xcode

    public init() {}

    public func canLoad(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "xcworkspace" || ext == "xcodeproj" { return true }
        return Self.findFirstProjectArtifact(in: url) != nil
    }

    public func load(at url: URL) throws -> ProjectModel {
        let resolved = try Self.resolveRoot(url)
        switch resolved.pathExtension.lowercased() {
        case "xcworkspace":
            return try loadWorkspace(at: resolved)
        case "xcodeproj":
            return try loadStandaloneProject(at: resolved)
        default:
            throw ProjectLoadError.unsupported(resolved)
        }
    }

    // MARK: - Workspace and project loading

    private func loadWorkspace(at workspaceURL: URL) throws -> ProjectModel {
        let workspace: XCWorkspace
        do {
            workspace = try XCWorkspace(path: Path(workspaceURL.path))
        } catch {
            throw ProjectLoadError.parseFailure(workspaceURL, reason: String(describing: error))
        }
        let workspaceDir = workspaceURL.deletingLastPathComponent()
        let projectURLs = Self.collectProjectURLs(
            from: workspace.data.children,
            workspaceDir: workspaceDir
        )
        var modules: [ProjectModule] = []
        modules.reserveCapacity(projectURLs.count)
        for projectURL in projectURLs {
            if let module = try? loadModule(at: projectURL) {
                modules.append(module)
            }
        }
        return ProjectModel(
            id: ProjectModelID(rawValue: workspaceURL.standardizedFileURL.path),
            displayName: workspaceURL.deletingPathExtension().lastPathComponent,
            rootURL: workspaceURL,
            adapter: .xcode,
            modules: modules
        )
    }

    private func loadStandaloneProject(at projectURL: URL) throws -> ProjectModel {
        let module = try loadModule(at: projectURL)
        return ProjectModel(
            id: ProjectModelID(rawValue: projectURL.standardizedFileURL.path),
            displayName: projectURL.deletingPathExtension().lastPathComponent,
            rootURL: projectURL,
            adapter: .xcode,
            modules: [module]
        )
    }

    private func loadModule(at projectURL: URL) throws -> ProjectModule {
        let xcodeProj: XcodeProj
        do {
            xcodeProj = try XcodeProj(path: Path(projectURL.path))
        } catch {
            throw ProjectLoadError.parseFailure(projectURL, reason: String(describing: error))
        }
        let pbxproj = xcodeProj.pbxproj
        guard let rootObject = pbxproj.rootObject else {
            throw ProjectLoadError.parseFailure(projectURL, reason: "missing rootObject")
        }
        let sourceRoot = Path(projectURL.deletingLastPathComponent().path)
        let targets = Self.collectTargets(from: rootObject, sourceRoot: sourceRoot)
        let memberships = Self.buildMembershipIndex(targets: rootObject.targets)
        let moduleID = ProjectModuleID(rawValue: projectURL.standardizedFileURL.path)
        let rootGroup = try Self.buildGroup(
            from: rootObject.mainGroup,
            moduleID: moduleID,
            parentPath: nil,
            displayPath: "",
            sourceRoot: sourceRoot,
            memberships: memberships
        )
        let configurations = Self.collectBuildConfigurations(
            from: rootObject,
            sourceRoot: sourceRoot
        )
        let schemes = Self.collectSchemes(
            xcodeProj: xcodeProj,
            projectURL: projectURL,
            targets: rootObject.targets
        )
        return ProjectModule(
            id: moduleID,
            displayName: projectURL.deletingPathExtension().lastPathComponent,
            rootURL: projectURL,
            rootGroup: rootGroup,
            targets: targets,
            configurations: configurations,
            schemes: schemes
        )
    }

    private static func collectBuildConfigurations(
        from project: PBXProject,
        sourceRoot: Path
    ) -> [BuildConfigSummary] {
        var out: [BuildConfigSummary] = []
        if let projectList = project.buildConfigurationList {
            for config in projectList.buildConfigurations {
                let base = config.baseConfiguration.flatMap { ref -> URL? in
                    guard let path = (try? ref.fullPath(sourceRoot: sourceRoot)).flatMap({ $0 }) else {
                        return nil
                    }
                    return URL(fileURLWithPath: path.string)
                }
                let raw = normalizeRawSettings(config.buildSettings)
                out.append(BuildConfigSummary(
                    id: BuildConfigID(rawValue: config.uuid),
                    name: config.name,
                    scope: .project,
                    baseConfigurationPath: base,
                    rawSettings: raw
                ))
            }
        }
        for target in project.targets {
            guard let native = target as? PBXNativeTarget,
                  let configList = native.buildConfigurationList else { continue }
            let targetID = TargetID(rawValue: native.uuid)
            for config in configList.buildConfigurations {
                let base = config.baseConfiguration.flatMap { ref -> URL? in
                    guard let path = (try? ref.fullPath(sourceRoot: sourceRoot)).flatMap({ $0 }) else {
                        return nil
                    }
                    return URL(fileURLWithPath: path.string)
                }
                let raw = normalizeRawSettings(config.buildSettings)
                out.append(BuildConfigSummary(
                    id: BuildConfigID(rawValue: config.uuid),
                    name: config.name,
                    scope: .target(targetID),
                    baseConfigurationPath: base,
                    rawSettings: raw
                ))
            }
        }
        return out
    }

    private static func normalizeRawSettings(_ source: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(source.count)
        for (key, value) in source {
            if let stringValue = value as? String {
                out[key] = stringValue
            } else if let arrayValue = value as? [String] {
                out[key] = arrayValue.joined(separator: " ")
            } else {
                out[key] = String(describing: value)
            }
        }
        return out
    }

    private static func collectSchemes(
        xcodeProj: XcodeProj,
        projectURL: URL,
        targets: [PBXTarget]
    ) -> [SchemeSummary] {
        var seen: Set<String> = []
        var out: [SchemeSummary] = []
        let targetNameToID: [String: TargetID] = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.name, TargetID(rawValue: $0.uuid))
        })
        for scheme in xcodeProj.sharedData?.schemes ?? [] {
            if seen.insert(scheme.name).inserted {
                out.append(schemeSummary(from: scheme, shared: true, targetNameToID: targetNameToID))
            }
        }
        for userData in xcodeProj.userData {
            for scheme in userData.schemes {
                if seen.insert(scheme.name).inserted {
                    out.append(schemeSummary(from: scheme, shared: false, targetNameToID: targetNameToID))
                }
            }
        }
        return out
    }

    private static func schemeSummary(
        from scheme: XCScheme,
        shared: Bool,
        targetNameToID: [String: TargetID]
    ) -> SchemeSummary {
        let knownTargetIDValues = Set(targetNameToID.values.map(\.rawValue))
        func resolve(_ ref: XCScheme.BuildableReference) -> TargetID? {
            if let direct = targetNameToID[ref.blueprintName] {
                return direct
            }
            if let blueprintUUID = ref.blueprintIdentifier,
               knownTargetIDValues.contains(blueprintUUID) {
                return TargetID(rawValue: blueprintUUID)
            }
            return nil
        }
        let runTargets = scheme.launchAction
            .flatMap { $0.runnable?.buildableReference }
            .flatMap(resolve)
            .map { [$0] } ?? []
        let testTargets: [TargetID] = scheme.testAction?.testables.compactMap { entry in
            resolve(entry.buildableReference)
        } ?? []
        let profileTarget = scheme.profileAction
            .flatMap { $0.buildableProductRunnable?.buildableReference }
            .flatMap(resolve)
        let archiveTarget = scheme.archiveAction
            .flatMap { $0.buildConfiguration }
            .flatMap { _ in
                scheme.buildAction?.buildActionEntries.first?.buildableReference
            }
            .flatMap(resolve)
        let args = scheme.launchAction?.commandlineArguments?.arguments
            .filter(\.enabled)
            .map(\.name) ?? []
        var env: [String: String] = [:]
        for variable in scheme.launchAction?.environmentVariables ?? [] where variable.enabled {
            env[variable.variable] = variable.value
        }
        return SchemeSummary(
            id: SchemeID(rawValue: scheme.name),
            name: scheme.name,
            isShared: shared,
            runTargetIDs: runTargets,
            testTargetIDs: testTargets,
            profileTargetID: profileTarget,
            archiveTargetID: archiveTarget,
            launchArguments: args,
            environmentVariables: env
        )
    }

    // MARK: - Group tree walk

    private static func buildGroup(
        from group: PBXGroup,
        moduleID: ProjectModuleID,
        parentPath: Path?,
        displayPath: String,
        sourceRoot: Path,
        memberships: MembershipIndex
    ) throws -> ProjectGroup {
        let resolvedPath = (try? group.fullPath(sourceRoot: sourceRoot)).flatMap { $0 }
        let groupName = group.name ?? group.path ?? "(group)"
        let childDisplayPath = displayPath.isEmpty ? groupName : "\(displayPath)/\(groupName)"
        let style = groupStyle(for: group)
        var children: [ProjectNodeKind] = []
        children.reserveCapacity(group.children.count)
        for child in group.children {
            if let subgroup = child as? PBXGroup {
                let built = try buildGroup(
                    from: subgroup,
                    moduleID: moduleID,
                    parentPath: resolvedPath,
                    displayPath: childDisplayPath,
                    sourceRoot: sourceRoot,
                    memberships: memberships
                )
                children.append(.group(built))
            } else if let synchronized = child as? PBXFileSystemSynchronizedRootGroup {
                let built = buildSynchronizedGroup(
                    from: synchronized,
                    moduleID: moduleID,
                    parentPath: resolvedPath,
                    displayPath: childDisplayPath,
                    sourceRoot: sourceRoot
                )
                children.append(.group(built))
            } else if let fileRef = child as? PBXFileReference {
                let file = buildFileNode(
                    from: fileRef,
                    moduleID: moduleID,
                    displayPath: childDisplayPath,
                    sourceRoot: sourceRoot,
                    memberships: memberships
                )
                children.append(.file(file))
            }
        }
        let nodeID = ProjectNodeID(rawValue: nodeIdentifier(
            moduleID: moduleID,
            displayPath: childDisplayPath,
            kind: "group"
        ))
        return ProjectGroup(
            id: nodeID,
            displayName: groupName,
            resolvedPath: (resolvedPath?.string).flatMap { URL(fileURLWithPath: $0) },
            style: style,
            children: children
        )
    }

    private static func buildSynchronizedGroup(
        from group: PBXFileSystemSynchronizedRootGroup,
        moduleID: ProjectModuleID,
        parentPath: Path?,
        displayPath: String,
        sourceRoot: Path
    ) -> ProjectGroup {
        let resolved = (try? group.fullPath(sourceRoot: sourceRoot)).flatMap { $0 }
        let name = group.name ?? group.path ?? "(synchronized)"
        let childDisplayPath = displayPath.isEmpty ? name : "\(displayPath)/\(name)"
        let resolvedURL = (resolved?.string).flatMap { URL(fileURLWithPath: $0) }
        var children: [ProjectNodeKind] = []
        if let resolvedURL,
           let walker = try? FileManager.default.contentsOfDirectory(
               at: resolvedURL,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for url in walker.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    children.append(.group(buildFilesystemGroup(
                        at: url,
                        moduleID: moduleID,
                        displayPath: childDisplayPath
                    )))
                } else {
                    let nodeID = ProjectNodeID(rawValue: nodeIdentifier(
                        moduleID: moduleID,
                        displayPath: childDisplayPath + "/" + url.lastPathComponent,
                        kind: "file"
                    ))
                    children.append(.file(ProjectFileNode(
                        id: nodeID,
                        displayName: url.lastPathComponent,
                        resolvedPath: url,
                        fileType: nil,
                        existsOnDisk: true,
                        memberships: []
                    )))
                }
            }
        }
        let id = ProjectNodeID(rawValue: nodeIdentifier(
            moduleID: moduleID,
            displayPath: childDisplayPath,
            kind: "group"
        ))
        return ProjectGroup(
            id: id,
            displayName: name,
            resolvedPath: resolvedURL,
            style: .synchronized,
            children: children
        )
    }

    private static func buildFilesystemGroup(
        at url: URL,
        moduleID: ProjectModuleID,
        displayPath: String
    ) -> ProjectGroup {
        let name = url.lastPathComponent
        let childDisplayPath = "\(displayPath)/\(name)"
        var children: [ProjectNodeKind] = []
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                children.append(.group(buildFilesystemGroup(
                    at: child,
                    moduleID: moduleID,
                    displayPath: childDisplayPath
                )))
            } else {
                let id = ProjectNodeID(rawValue: nodeIdentifier(
                    moduleID: moduleID,
                    displayPath: childDisplayPath + "/" + child.lastPathComponent,
                    kind: "file"
                ))
                children.append(.file(ProjectFileNode(
                    id: id,
                    displayName: child.lastPathComponent,
                    resolvedPath: child,
                    fileType: nil,
                    existsOnDisk: true,
                    memberships: []
                )))
            }
        }
        let id = ProjectNodeID(rawValue: nodeIdentifier(
            moduleID: moduleID,
            displayPath: childDisplayPath,
            kind: "group"
        ))
        return ProjectGroup(
            id: id,
            displayName: name,
            resolvedPath: url,
            style: .synchronized,
            children: children
        )
    }

    private static func buildFileNode(
        from ref: PBXFileReference,
        moduleID: ProjectModuleID,
        displayPath: String,
        sourceRoot: Path,
        memberships: MembershipIndex
    ) -> ProjectFileNode {
        let resolvedPath = (try? ref.fullPath(sourceRoot: sourceRoot)).flatMap { $0 }
        let name = ref.name ?? ref.path ?? "(file)"
        let childDisplayPath = displayPath.isEmpty ? name : "\(displayPath)/\(name)"
        let url = (resolvedPath?.string).flatMap { URL(fileURLWithPath: $0) }
        let exists: Bool = {
            guard let url else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }()
        let nodeID = ProjectNodeID(rawValue: nodeIdentifier(
            moduleID: moduleID,
            displayPath: childDisplayPath,
            kind: "file"
        ))
        let fileMemberships = memberships.memberships(forFileUUID: ref.uuid)
        return ProjectFileNode(
            id: nodeID,
            displayName: name,
            resolvedPath: url,
            fileType: ref.lastKnownFileType ?? ref.explicitFileType,
            existsOnDisk: exists,
            memberships: fileMemberships
        )
    }

    private static func groupStyle(for group: PBXGroup) -> ProjectGroupStyle {
        if group is PBXVariantGroup { return .variant }
        return .logical
    }

    // MARK: - Target summaries

    private static func collectTargets(
        from project: PBXProject,
        sourceRoot: Path
    ) -> [TargetSummary] {
        let projectXcconfigSettings = mergedXcconfigSettings(from: project.buildConfigurationList, sourceRoot: sourceRoot)
        return project.targets.compactMap { target -> TargetSummary? in
            guard let native = target as? PBXNativeTarget else { return nil }
            let productType = native.productType.flatMap { TargetProductType.fromXcodeProductType($0.rawValue) } ?? .other
            let targetXcconfig = mergedXcconfigSettings(from: native.buildConfigurationList, sourceRoot: sourceRoot)
            let resolved = resolveTargetMetadata(
                native: native,
                projectXcconfig: projectXcconfigSettings,
                targetXcconfig: targetXcconfig
            )
            let deps = native.dependencies.compactMap { dep -> TargetID? in
                if let resolved = dep.target?.uuid {
                    return TargetID(rawValue: resolved)
                }
                if let info = dep.targetProxy?.remoteInfo {
                    return TargetID(rawValue: "remote:\(info)")
                }
                return nil
            }
            return TargetSummary(
                id: TargetID(rawValue: native.uuid),
                displayName: native.name,
                productType: productType,
                platforms: resolved.platforms,
                bundleIdentifier: resolved.bundleIdentifier,
                deploymentTarget: resolved.deploymentTarget,
                dependencies: deps
            )
        }
    }

    private static func mergedXcconfigSettings(
        from configList: XCConfigurationList?,
        sourceRoot: Path
    ) -> [String: String] {
        guard let configs = configList?.buildConfigurations else { return [:] }
        var merged: [String: String] = [:]
        for config in configs {
            guard let ref = config.baseConfiguration,
                  let path = (try? ref.fullPath(sourceRoot: sourceRoot)).flatMap({ $0 }) else {
                continue
            }
            let url = URL(fileURLWithPath: path.string)
            guard let parsed = try? XcconfigParser.parse(at: url) else { continue }
            for (key, value) in parsed {
                merged[key] = value
            }
        }
        return merged
    }

    private struct ResolvedTargetMetadata {
        let bundleIdentifier: String?
        let deploymentTarget: String?
        let platforms: [String]
    }

    private static func resolveTargetMetadata(
        native: PBXNativeTarget,
        projectXcconfig: [String: String],
        targetXcconfig: [String: String]
    ) -> ResolvedTargetMetadata {
        let bundle = resolveSetting(
            key: "PRODUCT_BUNDLE_IDENTIFIER",
            native: native,
            projectXcconfig: projectXcconfig,
            targetXcconfig: targetXcconfig
        )
        let deploymentKeys = [
            "MACOSX_DEPLOYMENT_TARGET",
            "IPHONEOS_DEPLOYMENT_TARGET",
            "TVOS_DEPLOYMENT_TARGET",
            "WATCHOS_DEPLOYMENT_TARGET",
            "VISIONOS_DEPLOYMENT_TARGET"
        ]
        var deployment: String?
        for key in deploymentKeys {
            if let value = resolveSetting(
                key: key,
                native: native,
                projectXcconfig: projectXcconfig,
                targetXcconfig: targetXcconfig
            ), !value.isEmpty {
                deployment = value
                break
            }
        }
        var platforms: Set<String> = []
        if let supported = resolveSetting(
            key: "SUPPORTED_PLATFORMS",
            native: native,
            projectXcconfig: projectXcconfig,
            targetXcconfig: targetXcconfig
        ) {
            for piece in supported.split(separator: " ") {
                platforms.insert(String(piece))
            }
        }
        if let sdk = resolveSetting(
            key: "SDKROOT",
            native: native,
            projectXcconfig: projectXcconfig,
            targetXcconfig: targetXcconfig
        ) {
            platforms.insert(sdk)
        }
        return ResolvedTargetMetadata(
            bundleIdentifier: bundle,
            deploymentTarget: deployment,
            platforms: platforms.sorted()
        )
    }

    private static func resolveSetting(
        key: String,
        native: PBXNativeTarget,
        projectXcconfig: [String: String],
        targetXcconfig: [String: String]
    ) -> String? {
        if let configs = native.buildConfigurationList?.buildConfigurations {
            for config in configs {
                if let raw = config.buildSettings[key], let value = stringFromAny(raw), !value.isEmpty {
                    return value
                }
            }
        }
        if let value = targetXcconfig[key], !value.isEmpty { return value }
        if let value = projectXcconfig[key], !value.isEmpty { return value }
        return nil
    }

    private static func stringFromAny(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let a = value as? [String] { return a.joined(separator: " ") }
        return nil
    }

    // MARK: - Membership index

    private struct MembershipIndex {
        private let table: [String: [TargetMembership]]

        init(table: [String: [TargetMembership]]) {
            self.table = table
        }

        func memberships(forFileUUID uuid: String) -> [TargetMembership] {
            table[uuid] ?? []
        }
    }

    private static func buildMembershipIndex(targets: [PBXTarget]) -> MembershipIndex {
        var table: [String: [TargetMembership]] = [:]
        for target in targets {
            let targetID = TargetID(rawValue: target.uuid)
            for phase in target.buildPhases {
                let role = role(for: phase)
                for buildFile in phase.files ?? [] {
                    guard let fileUUID = buildFile.file?.uuid else { continue }
                    let flags = (buildFile.settings?["COMPILER_FLAGS"] as? String)
                        .map { $0.split(separator: " ").map(String.init) }
                        ?? []
                    table[fileUUID, default: []].append(
                        TargetMembership(targetID: targetID, role: role, compilerFlags: flags)
                    )
                }
            }
        }
        return MembershipIndex(table: table)
    }

    private static func role(for phase: PBXBuildPhase) -> TargetMembershipRole {
        switch phase.buildPhase {
        case .sources: return .compile
        case .resources: return .resource
        case .frameworks: return .framework
        case .headers: return .header
        case .copyFiles: return .copy
        case .runScript: return .script
        case .carbonResources: return .resource
        @unknown default: return .resource
        }
    }

    // MARK: - URL and path resolution

    private static func resolveRoot(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let ext = standardized.pathExtension.lowercased()
        if ext == "xcworkspace" || ext == "xcodeproj" {
            guard FileManager.default.fileExists(atPath: standardized.path) else {
                throw ProjectLoadError.unreadable(standardized)
            }
            return standardized
        }
        guard let candidate = findFirstProjectArtifact(in: standardized) else {
            throw ProjectLoadError.unsupported(standardized)
        }
        return candidate
    }

    private static func findFirstProjectArtifact(in url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        if let ws = contents.first(where: { $0.pathExtension.lowercased() == "xcworkspace" }) {
            return ws
        }
        return contents.first(where: { $0.pathExtension.lowercased() == "xcodeproj" })
    }

    private static func collectProjectURLs(
        from elements: [XCWorkspaceDataElement],
        workspaceDir: URL
    ) -> [URL] {
        var out: [URL] = []
        for element in elements {
            switch element {
            case let .file(ref):
                let resolved = resolveWorkspaceLocation(ref.location, workspaceDir: workspaceDir)
                if resolved.pathExtension.lowercased() == "xcodeproj" {
                    out.append(resolved)
                }
            case let .group(group):
                let nested = collectProjectURLs(from: group.children, workspaceDir: workspaceDir)
                out.append(contentsOf: nested)
            }
        }
        return out
    }

    private static func resolveWorkspaceLocation(
        _ location: XCWorkspaceDataElementLocationType,
        workspaceDir: URL
    ) -> URL {
        let raw = location.path
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        return URL(fileURLWithPath: raw, relativeTo: workspaceDir).standardizedFileURL
    }

    private static func nodeIdentifier(
        moduleID: ProjectModuleID,
        displayPath: String,
        kind: String
    ) -> String {
        "\(moduleID.rawValue)|\(kind)|\(displayPath)"
    }
}
