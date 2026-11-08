// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXProjectModel",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXProjectModel",
            targets: ["CMUXProjectModel"]
        ),
        .executable(
            name: "cmux-project-dump",
            targets: ["CMUXProjectDump"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXProjectModel"
        ),
        .executableTarget(
            name: "CMUXProjectDump",
            dependencies: ["CMUXProjectModel"]
        ),
        .testTarget(
            name: "CMUXProjectModelTests",
            dependencies: ["CMUXProjectModel"]
        ),
    ]
)
