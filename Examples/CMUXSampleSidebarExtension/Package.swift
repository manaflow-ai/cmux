// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CMUXSampleSidebarExtension",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "CMUXSampleSidebarExtension",
            targets: ["CMUXSampleSidebarExtension"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/CmuxExtensionKit"),
    ],
    targets: [
        .target(
            name: "CMUXSampleSidebarExtension",
            dependencies: ["CmuxExtensionKit"]
        ),
        .testTarget(
            name: "CMUXSampleSidebarExtensionTests",
            dependencies: ["CMUXSampleSidebarExtension"]
        ),
    ]
)
