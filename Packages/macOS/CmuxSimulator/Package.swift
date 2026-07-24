// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSimulator",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxSimulator", targets: ["CmuxSimulator"]),
        .library(name: "CmuxSimulatorUI", targets: ["CmuxSimulatorUI"]),
        .library(name: "CmuxSimulatorWorker", targets: ["CmuxSimulatorWorker"]),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSimulatorSystem",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CmuxSimulator",
            dependencies: [
                "CmuxSimulatorSystem",
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CmuxSimulatorWorker",
            dependencies: ["CmuxSimulator", "CmuxSimulatorSystem"],
            resources: [
                .copy("Resources/CameraInjector"),
                .copy("Resources/SimulatorAXSettings"),
                .copy("Resources/WebInspector"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .target(
            name: "CmuxSimulatorUI",
            dependencies: ["CmuxSimulator", "CmuxSimulatorSystem"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(
            name: "CmuxSimulatorTests",
            dependencies: ["CmuxSimulator"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxSimulatorUITests",
            dependencies: [
                "CmuxSimulatorSystem",
                "CmuxSimulatorUI",
                "CmuxSimulatorWorker",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxSimulatorWorkerTests",
            dependencies: ["CmuxSimulator", "CmuxSimulatorWorker"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
