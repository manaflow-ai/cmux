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
    dependencies: [
        .package(
            url: "https://github.com/tuist/XcodeProj.git",
            from: "9.0.0"
        ),
    ],
    targets: [
        .target(
            name: "CMUXProjectModel",
            dependencies: [
                .product(name: "XcodeProj", package: "XcodeProj"),
            ]
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
