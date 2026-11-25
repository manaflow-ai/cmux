// swift-tools-version: 6.2

import Foundation
import PackageDescription

// A dependency-free RFB (VNC) client engine shared by the cmux-next Mac app
// (the `remote_view` pane's compatibility source, plans/cmux-next/remote-desktop.md
// section 12) and iOS clients. `CmuxVNCDemoServer` is a small loopback RFB
// server that paints a synthetic desktop, for tests and offline demos.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

let linuxTesting = ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1"
let zlibLinkerSettings: [LinkerSetting] = [.linkedLibrary("z")]
let zlibDependencies: [Target.Dependency] = linuxTesting ? ["zlib"] : []

let package = Package(
    name: "CmuxVNC",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxVNC", targets: ["CmuxVNC"]),
        .library(name: "CmuxVNCDemoServer", targets: ["CmuxVNCDemoServer"]),
    ],
    dependencies: [
        .package(path: "../CmuxEgress"),
    ],
    targets: [
        .systemLibrary(name: "zlib", path: "Sources/zlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
        .target(name: "CmuxVNC", dependencies: [.product(name: "CmuxEgress", package: "CmuxEgress")] + zlibDependencies, swiftSettings: swiftSettings, linkerSettings: zlibLinkerSettings),
        .target(name: "CmuxVNCDemoServer", dependencies: ["CmuxVNC"] + zlibDependencies, swiftSettings: swiftSettings,
                linkerSettings: zlibLinkerSettings),
        .testTarget(name: "CmuxVNCTests", dependencies: ["CmuxVNC", "CmuxVNCDemoServer"] + zlibDependencies, swiftSettings: swiftSettings,
                    linkerSettings: zlibLinkerSettings),
    ]
)

#if os(Linux)
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    for targetName in ["CmuxVNC", "CmuxVNCTests"] {
        package.targets.first { $0.name == targetName }?.dependencies.append(
            .product(name: "Crypto", package: "swift-crypto")
        )
        package.targets.first { $0.name == targetName }?.dependencies.append(
            .product(name: "_CryptoExtras", package: "swift-crypto")
        )
    }
}
#endif
