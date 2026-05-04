// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CMUXSimulator",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CMUXSimulator", targets: ["CMUXSimulator"])
    ],
    targets: [
        .target(
            name: "CMUXSimulator",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .testTarget(
            name: "CMUXSimulatorTests",
            dependencies: ["CMUXSimulator"]
        )
    ]
)
