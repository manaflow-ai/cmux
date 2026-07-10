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
            name: "CmuxSimulatorObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("QuartzCore"),
            ]
        ),
        .target(
            name: "CmuxSimulator",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CmuxSimulatorWorker",
            dependencies: ["CmuxSimulator"],
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
                .linkedFramework("QuartzCore"),
            ]
        ),
        .target(
            name: "CmuxSimulatorUI",
            dependencies: ["CmuxSimulator", "CmuxSimulatorObjC"],
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
            dependencies: ["CmuxSimulatorUI", "CmuxSimulatorWorker"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxSimulatorWorkerTests",
            dependencies: ["CmuxSimulatorWorker"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
