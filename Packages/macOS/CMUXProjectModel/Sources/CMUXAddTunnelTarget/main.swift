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
    static let wireGuardURL = "https://github.com/JacobZwang/wireguard-apple.git"
    /// `cmux-xcode26-compat`, pinned by revision so the dependency cannot move
    /// under us.
    static let wireGuardRevision = "e79c3f898f7cb03493c65b9732c6990c011cab92"

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

        // WireGuardKit, which the provider uses to move packets.
        //
        // A fork, not upstream, and pinned by revision. Upstream does not build
        // on current Xcode: its manifest declares `.macOS(.v12)`/`.iOS(.v15)`
        // under swift-tools-version 5.3 where those cases do not exist, so
        // SwiftPM will not resolve it; and `WireGuardKitC.h` uses `u_int32_t`
        // without including <sys/types.h>, which the explicit-module build
        // rejects. Neither is fixable from here -- target build settings do not
        // reach a remote package's C target -- so the fork carries those two
        // changes and nothing else. Retire it when upstream takes them.
        let wireGuard = XCRemoteSwiftPackageReference(
            repositoryURL: wireGuardURL,
            versionRequirement: .revision(wireGuardRevision)
        )
        pbxproj.add(object: wireGuard)
        root.remotePackages.append(wireGuard)
        let wireGuardProduct = XCSwiftPackageProductDependency(
            productName: "WireGuardKit",
            package: wireGuard
        )
        pbxproj.add(object: wireGuardProduct)

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

        // WireGuardKitGo declares `.linkedLibrary("wg-go")` but does not build
        // it: upstream expects its host project to run the Makefile, which
        // emits libwg-go.a into CONFIGURATION_BUILD_DIR -- already on the link
        // path. Without this phase the extension fails at link with
        // "library 'wg-go' not found".
        let goBridge = PBXShellScriptBuildPhase(
            name: "Build WireGuard Go Bridge",
            shellScript: """
            set -euo pipefail
            CHECKOUT="${BUILD_DIR}/../../SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo"
            if [ ! -d "$CHECKOUT" ]; then
              echo "error: WireGuardKitGo checkout not found at $CHECKOUT" >&2
              exit 1
            fi
            # The Makefile reads ARCHS, SDKROOT and the build dirs from Xcode's
            # environment, so it needs no arguments beyond the goal.
            make -C "$CHECKOUT" build
            """
        )
        pbxproj.add(object: goBridge)

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
            // An embedded binary's id must be prefixed by its host's, and the
            // host's id is not fixed: `scripts/reload.sh --tag` passes
            // PRODUCT_BUNDLE_IDENTIFIER as a command-line build setting, which
            // applies to every target. So the extension derives its id from
            // whatever the host ended up with rather than naming one. A plain
            // build composes com.cmuxterm.app.debug.network-extension; a tagged
            // build composes com.cmuxterm.app.debug.<tag>.network-extension,
            // and neither needs reload.sh to know this target exists.
            "PRODUCT_BUNDLE_IDENTIFIER": "com.cmuxterm.app",
            "CMUX_TUNNEL_EXTENSION_BUNDLE_ID": "$(PRODUCT_BUNDLE_IDENTIFIER).network-extension",
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
        debugSettings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.cmuxterm.app.debug"
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
            buildPhases: [goBridge, sources, frameworks, resources],
            product: product,
            productType: .appExtension
        )
        target.packageProductDependencies = [wireGuardProduct]
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
