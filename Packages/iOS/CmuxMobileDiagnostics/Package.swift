// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileDiagnostics",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileDiagnostics",
            targets: ["CmuxMobileDiagnostics"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileDiagnostics",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileDiagnosticsTests",
            dependencies: ["CmuxMobileDiagnostics"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
