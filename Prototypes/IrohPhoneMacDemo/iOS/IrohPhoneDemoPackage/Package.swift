// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "IrohPhoneDemoFeature",
    platforms: [.iOS(.v17)],
    products: [
        .library(
            name: "IrohPhoneDemoFeature",
            targets: ["IrohPhoneDemoFeature"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "IrohPhoneMacFFI",
            path: "Binaries/IrohPhoneMacFFI.xcframework"
        ),
        .target(
            name: "IrohPhoneDemoFeature",
            dependencies: ["IrohPhoneMacFFI"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("resolv"),
            ]
        ),
    ]
)
