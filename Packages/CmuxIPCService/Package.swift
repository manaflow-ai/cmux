// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxIPCService",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxIPCService",
            targets: ["CmuxIPCService"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxIPCService",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxIPCServiceTests",
            dependencies: ["CmuxIPCService"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
