// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalBackendService",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalBackendService",
            targets: ["CmuxTerminalBackendService"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalBackend"),
    ],
    targets: [
        .target(
            name: "CmuxTerminalBackendService",
            dependencies: [
                .product(
                    name: "CmuxTerminalBackend",
                    package: "CmuxTerminalBackend"
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("bsm"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalBackendServiceTests",
            dependencies: [
                .product(
                    name: "CmuxTerminalBackend",
                    package: "CmuxTerminalBackend"
                ),
                "CmuxTerminalBackendService",
            ]
        ),
    ]
)
