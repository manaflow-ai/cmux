// swift-tools-version: 6.2
//
// CMUXCEF — cmux-owned Swift facade for embedding CEF Chrome runtime
// browsers inside cmux. See CEF/README.md and CEF/INTEGRATION.md for
// the local build and app-runtime installation model.
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
// `vendor/fetch_cef.sh`. `./scripts/setup.sh` runs it for cmux source
// checkouts; installed cmux apps download the CEF runtime separately on
// first CEF use.

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
        // Keep the package buildable at cmux's deployment target so the app can
        // launch and fall back to WKWebView on older hosts. CEFEngine.start()
        // and the helper bundles enforce the actual CEF runtime floor:
        // macOS 15.0 or later.
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
                // -L/-F before -l/-weak_framework. `.linkedLibrary` /
                // `.linkedFramework` are not used because SwiftPM/Xcode
                // do not preserve their position relative to unsafeFlags.
                .unsafeFlags([
                    "-L", cefFrameworksDir,
                    "-F", cefFrameworksDir,
                    "-lcef_dll_wrapper",
                    // Keep the CEF framework weak-linked so cmux can launch
                    // before the optional runtime has been installed. The
                    // bridge calls cef_load_library() with the resolved
                    // runtime path before touching CEF APIs.
                    "-Xlinker", "-weak_framework",
                    "-Xlinker", "Chromium Embedded Framework",
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
