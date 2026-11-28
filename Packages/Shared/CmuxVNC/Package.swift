// swift-tools-version: 6.2

import Foundation
import PackageDescription

// An RFB (VNC) client engine shared by the cmux-next Mac app
// (the `remote_view` pane's compatibility source, plans/cmux-next/remote-desktop.md
// section 12) and iOS clients. `CmuxVNCDemoServer` is a small loopback RFB
// server that paints a synthetic desktop, for tests and offline demos.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

var linuxTarget = false
var packageDependencies: [Package.Dependency] = [.package(path: "../CmuxEgress")]
#if os(Linux)
// Apple SDKs provide CryptoKit and zlib, including when cross-compiling on Linux.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    linuxTarget = true
    packageDependencies = [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")]
}
#endif

let zlib: [Target.Dependency] = linuxTarget ? ["zlib"] : []
let engineDependencies: [Target.Dependency] = linuxTarget ? [
    .product(name: "Crypto", package: "swift-crypto"),
    .product(name: "_CryptoExtras", package: "swift-crypto"),
] + zlib : [.product(name: "CmuxEgress", package: "CmuxEgress")]

let package = Package(
    name: "CmuxVNC",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CmuxVNC", targets: ["CmuxVNC"])] + (linuxTarget ? [] : [
        .library(name: "CmuxVNCDemoServer", targets: ["CmuxVNCDemoServer"]),
    ]),
    dependencies: packageDependencies,
    targets: [
        .target(name: "CmuxVNC", dependencies: engineDependencies,
                swiftSettings: swiftSettings, linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CmuxVNCDemoServer", dependencies: ["CmuxVNC"] + zlib,
                swiftSettings: swiftSettings, linkerSettings: [.linkedLibrary("z")]),
        .testTarget(name: "CmuxVNCTests", dependencies: ["CmuxVNC", "CmuxVNCDemoServer"] + zlib,
                    swiftSettings: swiftSettings),
    ] + (linuxTarget ? [
        .systemLibrary(name: "zlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
    ] : [
        .testTarget(name: "CmuxVNCIntegrationTests", dependencies: ["CmuxVNC", "CmuxVNCDemoServer"],
                    swiftSettings: swiftSettings),
    ])
)
