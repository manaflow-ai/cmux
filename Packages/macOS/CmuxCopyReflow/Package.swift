// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CmuxCopyReflow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CmuxCopyReflow",
            targets: ["CmuxCopyReflow"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxCopyReflow",
            path: "Sources/CmuxCopyReflow"
        ),
        .testTarget(
            name: "CmuxCopyReflowTests",
            dependencies: ["CmuxCopyReflow"],
            path: "Tests/CmuxCopyReflowTests"
        ),
    ]
)
