// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileSimulatorStream",
    platforms: [
        .iOS(.v18),
        // macOS so the mapping logic unit-tests locally.
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileSimulatorStream",
            targets: ["CmuxMobileSimulatorStream"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CmuxMobileSimulatorStream",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxMobileSimulatorStreamTests",
            dependencies: ["CmuxMobileSimulatorStream"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
