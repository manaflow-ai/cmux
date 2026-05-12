// swift-tools-version: 6.2
//
// CMUXCEF — cmux-owned Swift facade for embedding CEF Chrome runtime
// browsers inside cmux. See DESIGN.md alongside this package for the
// architectural decisions.
//
// This package is intentionally **isolated**:
//   * It depends only on the system AppKit / Foundation modules and on
//     the CEF framework + libcef_dll_wrapper.a placed by
//     vendor/fetch_cef.sh.
//   * It does **not** import anything from cmux.app.
//   * It produces a public Swift library (CMUXCEF) plus two helper
//     executables (CMUXCEFHelper, CMUXCEFHelperRenderer) that ship as
//     embedded helper .app bundles inside cmux.app/Contents/Frameworks/.
//
// The Frameworks/ directory layout consumed here is the one prepared by
// `vendor/fetch_cef.sh`. Run that script before building this package.
//
// Path used here is relative to the package root and points at the
// existing prototype Frameworks/ directory. When this package is moved
// into cmux proper, the path moves with it (e.g. `../../../Frameworks`)
// or — preferably — the cmux Xcode project sets `FRAMEWORK_SEARCH_PATHS`
// / `LIBRARY_SEARCH_PATHS` and we drop the `.unsafeFlags` here.

import Foundation
import PackageDescription

// `vendor/fetch_cef.sh` produces:
//   <package>/Frameworks/Chromium Embedded Framework.framework
//   <package>/Frameworks/libcef_dll_wrapper.a
//   <package>/Frameworks/include/
// We point cxxSettings + linkerSettings at that Frameworks/ directory.
// (Inside the prototype we used a `CEFArtifacts` symlink; in the cmux
// vendored copy we drop straight into `Frameworks/`.)
private let cefFrameworksDir: String = {
    let pkgDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return pkgDir.appendingPathComponent("Frameworks").path
}()

let package = Package(
    name: "CMUXCEF",
    platforms: [
        // CEF 146 requires macOS 14+ at runtime. We declare 14 to match cmux's
        // deployment target so linking succeeds; CEFEngine.start() runtime-
        // checks for macOS 15 features (menubar / window-controls) and
        // throws CEFEngineError.unsupportedOperatingSystem on older hosts.
        .macOS(.v14),
    ],
    products: [
        .library(name: "CMUXCEF", targets: ["CMUXCEF"]),
        .executable(name: "CMUXCEFHelper", targets: ["CMUXCEFHelper"]),
        .executable(name: "CMUXCEFHelperRenderer", targets: ["CMUXCEFHelperRenderer"]),
        .executable(name: "CMUXCEFDemoApp", targets: ["CMUXCEFDemoApp"]),
    ],
    targets: [
        // MARK: - Bridge — ObjC++ bridge that owns all CEF C++ interop.
        .target(
            name: "CMUXCEFBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Frameworks/include"),
                .headerSearchPath("../../Frameworks"),
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                // Everything in one unsafeFlags block so the linker sees
                // -L/-F BEFORE -l/-framework. `.linkedLibrary` /
                // `.linkedFramework` are not used because SwiftPM/Xcode
                // do not preserve their position relative to unsafeFlags
                // on the resulting link command, which made the linker
                // skip libcef_dll_wrapper.a and import nothing from the
                // Chromium framework.
                .unsafeFlags([
                    "-L", cefFrameworksDir,
                    "-F", cefFrameworksDir,
                    "-Xlinker", "-rpath", "-Xlinker", cefFrameworksDir,
                    "-lcef_dll_wrapper",
                    "-framework", "Chromium Embedded Framework",
                ]),
            ]
        ),

        // MARK: - CMUXCEF — Swift facade. The only API cmux app code
        // imports.
        .target(
            name: "CMUXCEF",
            dependencies: ["CMUXCEFBridge"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),

        // MARK: - Helper executables. Both are tiny — they exist solely
        // so CEF's multi-process launcher has a binary to spawn for each
        // helper role. Real per-process logic lives in CEF itself.
        .executableTarget(
            name: "CMUXCEFHelper",
            dependencies: ["CMUXCEFBridge"],
            sources: ["main.mm"],
            cxxSettings: [
                .headerSearchPath("../../Frameworks/include"),
                .headerSearchPath("../../Frameworks"),
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .unsafeFlags([
                    "-L", cefFrameworksDir,
                    "-F", cefFrameworksDir,
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../..",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "CMUXCEFHelperRenderer",
            dependencies: ["CMUXCEFBridge"],
            sources: ["main.mm"],
            cxxSettings: [
                .headerSearchPath("../../Frameworks/include"),
                .headerSearchPath("../../Frameworks"),
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .unsafeFlags([
                    "-L", cefFrameworksDir,
                    "-F", cefFrameworksDir,
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../..",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../Frameworks",
                ]),
            ]
        ),

        // MARK: - Demo / smoke executable. Runs an end-to-end check that
        // CEFEngine.start + makeBrowser produce a working Chrome runtime
        // window. Not shipped; for local development only.
        .executableTarget(
            name: "CMUXCEFDemoApp",
            dependencies: ["CMUXCEF"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", cefFrameworksDir,
                ]),
            ]
        ),

        // MARK: - Tests. Behavioral; no source-grep tests.
        .testTarget(
            name: "CMUXCEFTests",
            dependencies: ["CMUXCEF"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
