import Foundation
import PathKit
import XcodeProj

/// Adds the packet tunnel provider extension target to cmux.xcodeproj.
///
/// A one-shot generator rather than a hand-edited project file: adding an
/// app-extension target touches a native target, its build phases and
/// configuration list, a product reference, an embed phase on the app, a
/// target dependency, and a package product dependency. Writing that by hand
/// into a 14k-line pbxproj is how a project file gets subtly corrupted, and
/// this project has no extension target to copy from.
///
/// Idempotent: running it twice leaves one target.
///
///     swift run --package-path Packages/macOS/CMUXProjectModel \
///       cmux-add-tunnel-target <path to cmux.xcodeproj>
@main
struct CMUXAddTunnelTarget {
    static let targetName = "CmuxTunnelExtension"

    static func main() throws {
        var arguments = CommandLine.arguments.dropFirst()
        let rawPath = arguments.popFirst() ?? "cmux.xcodeproj"
        let path = Path(rawPath)
        let project = try XcodeProj(path: path)
        let pbxproj = project.pbxproj

        guard let root = pbxproj.rootObject else {
            throw Failure("project has no root object")
        }
        guard let appTarget = pbxproj.nativeTargets.first(where: { $0.name == "cmux" }) else {
            throw Failure("no app target named cmux")
        }
        if pbxproj.nativeTargets.contains(where: { $0.name == targetName }) {
            print("\(targetName) already present; nothing to do")
            return
        }

        // No WireGuard package is wired in yet, deliberately. `wireguard-apple`
        // on master does not resolve (its manifest declares `.macOS(.v12)` /
        // `.iOS(.v15)` under swift-tools-version 5.3, where those cases do not
        // exist), and 1.0.15-26 -- the newest self-consistent manifest -- then
        // fails to compile, because `WireGuardKitC.h` uses `u_int32_t` without
        // including <sys/types.h> and the current toolchain's module build
        // rejects that. Target build settings do not reach a remote package's
        // C target, so there is no override from here.
        //
        // Choosing between vendoring a patched copy, adopting a maintained
        // fork, or waiting for upstream is a dependency decision, so this adds
        // the target and leaves the implementation to that decision.

        // Sources live in a folder group beside the app's.
        let group = PBXGroup(sourceTree: .group, name: targetName, path: targetName)
        pbxproj.add(object: group)
        root.mainGroup?.children.append(group)

        let sourceFile = PBXFileReference(
            sourceTree: .group,
            lastKnownFileType: "sourcecode.swift",
            path: "PacketTunnelProvider.swift"
        )
        let infoPlist = PBXFileReference(
            sourceTree: .group,
            lastKnownFileType: "text.plist.xml",
            path: "Info.plist"
        )
        let entitlements = PBXFileReference(
            sourceTree: .group,
            lastKnownFileType: "text.plist.entitlements",
            path: "\(targetName).entitlements"
        )
        for file in [sourceFile, infoPlist, entitlements] {
            pbxproj.add(object: file)
            group.children.append(file)
        }

        let sourceBuildFile = PBXBuildFile(file: sourceFile)
        pbxproj.add(object: sourceBuildFile)
        let sources = PBXSourcesBuildPhase(files: [sourceBuildFile])
        pbxproj.add(object: sources)
        let frameworks = PBXFrameworksBuildPhase(files: [])
        pbxproj.add(object: frameworks)
        let resources = PBXResourcesBuildPhase(files: [])
        pbxproj.add(object: resources)

        // Signing is inherited from the app: the entitlement Apple grants is
        // per team, and an extension signed differently from its host cannot
        // load.
        let common: [String: Any] = [
            "PRODUCT_NAME": "$(TARGET_NAME)",
            // Literal per configuration, the way the dock tile plugin does it:
            // an embedded binary's id must be prefixed by its host's, and there
            // is no build setting holding the host's id to derive from.
            //
            // Note this does not survive `scripts/reload.sh --tag`, which
            // passes PRODUCT_BUNDLE_IDENTIFIER as a command-line build setting.
            // Those apply to every target, so a tagged build gives the
            // extension the host's own id and the embed check rejects it. That
            // mechanism needs to compose ids per target -- via an xcconfig or a
            // suffix setting -- before tagged builds can carry an extension.
            "PRODUCT_BUNDLE_IDENTIFIER": "com.cmuxterm.app.network-extension",
            "INFOPLIST_FILE": "\(targetName)/Info.plist",
            "CODE_SIGN_ENTITLEMENTS": "\(targetName)/\(targetName).entitlements",
            "SKIP_INSTALL": "YES",
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "CODE_SIGN_STYLE": "Automatic",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "LD_RUNPATH_SEARCH_PATHS": [
                "$(inherited)",
                "@executable_path/../Frameworks",
                "@executable_path/../../../../Frameworks",
            ],
        ]
        // Debug carries no entitlements, mirroring the app target. The
        // NetworkExtension entitlement requires a development certificate, and
        // local builds sign ad-hoc ("Sign to Run Locally"), so demanding it in
        // Debug fails the build for everyone -- including people not touching
        // the VPN. The extension cannot load without it either way; Release is
        // where it matters.
        var debugSettings = common
        debugSettings["CODE_SIGN_ENTITLEMENTS"] = ""
        debugSettings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.cmuxterm.app.debug.network-extension"
        let debug = XCBuildConfiguration(name: "Debug", buildSettings: buildSettings(debugSettings))
        let release = XCBuildConfiguration(name: "Release", buildSettings: buildSettings(common))
        pbxproj.add(object: debug)
        pbxproj.add(object: release)
        let configurations = XCConfigurationList(
            buildConfigurations: [debug, release],
            defaultConfigurationName: "Release"
        )
        pbxproj.add(object: configurations)

        let product = PBXFileReference(
            sourceTree: .buildProductsDir,
            explicitFileType: "wrapper.app-extension",
            path: "\(targetName).appex",
            includeInIndex: false
        )
        pbxproj.add(object: product)
        root.productsGroup?.children.append(product)

        let target = PBXNativeTarget(
            name: targetName,
            buildConfigurationList: configurations,
            buildPhases: [sources, frameworks, resources],
            product: product,
            productType: .appExtension
        )
        pbxproj.add(object: target)
        root.targets.append(target)

        // The app embeds the extension and must build it first, or the host
        // ships without the thing that runs its VPN.
        let embedFile = PBXBuildFile(
            file: product,
            settings: ["ATTRIBUTES": ["RemoveHeadersOnCopy"]]
        )
        pbxproj.add(object: embedFile)
        let embed = PBXCopyFilesBuildPhase(
            dstPath: "",
            dstSubfolderSpec: .plugins,
            name: "Embed Network Extension",
            files: [embedFile]
        )
        pbxproj.add(object: embed)
        appTarget.buildPhases.append(embed)

        let dependency = PBXTargetDependency(target: target)
        pbxproj.add(object: dependency)
        appTarget.dependencies.append(dependency)

        try project.write(path: path)
        print("added \(targetName) and embedded it in cmux")
    }

    private static func buildSettings(_ raw: [String: Any]) -> [String: BuildSetting] {
        raw.reduce(into: [:]) { output, entry in
            if let string = entry.value as? String {
                output[entry.key] = .string(string)
            } else if let array = entry.value as? [String] {
                output[entry.key] = .array(array)
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
