// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileSimulatorStream",
    platforms: [
        .iOS(.v18),
        // macOS so the engine, mapping, and store logic unit-test locally;
        // the display view itself is UIKit-gated.
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileSimulatorStream",
            targets: ["CmuxMobileSimulatorStream"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxSimulatorStreamKit"),
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxMobileRPC"),
    ],
    targets: [
        .target(
            name: "CmuxMobileSimulatorStream",
            dependencies: [
                "CmuxSimulatorStreamKit",
                "CMUXMobileCore",
                "CmuxMobileRPC",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxMobileSimulatorStreamTests",
            dependencies: ["CmuxMobileSimulatorStream"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
