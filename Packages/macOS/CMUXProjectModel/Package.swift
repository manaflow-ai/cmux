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
        .executable(
            name: "cmux-add-tunnel-target",
            targets: ["CMUXAddTunnelTarget"]
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
        .executableTarget(
            name: "CMUXAddTunnelTarget",
            dependencies: [
                .product(name: "XcodeProj", package: "XcodeProj"),
            ]
        ),
        .testTarget(
            name: "CMUXProjectModelTests",
            dependencies: ["CMUXProjectModel"]
        ),
    ]
)
