// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxExtensionSidebarExamples",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "CmuxExtensionSidebarExamples",
            targets: ["CmuxExtensionSidebarExamples"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/CmuxExtensionKit"),
    ],
    targets: [
        .target(
            name: "CmuxExtensionSidebarExamples",
            dependencies: ["CmuxExtensionKit"]
        ),
        .testTarget(
            name: "CmuxExtensionSidebarExamplesTests",
            dependencies: ["CmuxExtensionSidebarExamples"]
        ),
    ]
)
