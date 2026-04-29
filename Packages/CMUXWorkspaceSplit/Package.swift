// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CMUXWorkspaceSplit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CMUXWorkspaceSplit", targets: ["CMUXWorkspaceSplit"])
    ],
    targets: [
        .target(name: "CMUXWorkspaceSplit"),
        .testTarget(
            name: "CMUXWorkspaceSplitTests",
            dependencies: ["CMUXWorkspaceSplit"]
        )
    ]
)
