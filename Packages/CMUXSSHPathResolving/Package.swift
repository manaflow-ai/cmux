// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXSSHPathResolving",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CMUXSSHPathResolving",
            targets: ["CMUXSSHPathResolving"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXSSHPathResolving",
            path: "Sources/CMUXSSHPathResolving"
        ),
        .testTarget(
            name: "CMUXSSHPathResolvingTests",
            dependencies: ["CMUXSSHPathResolving"],
            path: "Tests/CMUXSSHPathResolvingTests"
        ),
    ]
)
