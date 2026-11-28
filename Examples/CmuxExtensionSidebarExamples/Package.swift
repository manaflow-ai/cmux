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
        .package(path: "../../Packages/macOS/CmuxSidebarProviderKit"),
    ],
    targets: [
        .target(
            name: "CmuxExtensionSidebarExamples",
            dependencies: ["CmuxSidebarProviderKit"]
        ),
        .testTarget(
            name: "CmuxExtensionSidebarExamplesTests",
            dependencies: ["CmuxExtensionSidebarExamples"]
        ),
    ]
)
