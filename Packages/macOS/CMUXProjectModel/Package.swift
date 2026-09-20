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
    // XcodeProj 9.x still depends on PathKit 1.0.1, whose Swift 4.2 manifest
    // prevents explicit-module compilation caching. The package-local mirror
    // maps that URL to the public cmux-maintained 1.0.2 fork, which changes only
    // the tools-version declaration. .swiftpm/configuration/mirrors.json links to
    // the tracked config/swiftpm/mirrors.json, and the build and test entry points
    // set SWIFTPM_MIRROR_CONFIG to the same file. Remove the mirror and lockfile
    // pin when upstream PathKit publishes a modern manifest.
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
