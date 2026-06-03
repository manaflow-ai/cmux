// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalCore",
            targets: ["CmuxTerminalCore"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxMobileContract"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.96.0"),
    ],
    targets: [
        .target(
            name: "CmuxTerminalCore",
            dependencies: [
                .product(name: "CmuxMobileContract", package: "CmuxMobileContract"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalCoreTests",
            dependencies: ["CmuxTerminalCore"]
        ),
    ]
)
