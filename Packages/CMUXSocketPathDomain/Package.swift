// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXSocketPathDomain",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CMUXSocketPathDomain",
            targets: ["CMUXSocketPathDomain"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXSocketPathDomain"
        ),
        .testTarget(
            name: "CMUXSocketPathDomainTests",
            dependencies: ["CMUXSocketPathDomain"]
        ),
    ]
)
