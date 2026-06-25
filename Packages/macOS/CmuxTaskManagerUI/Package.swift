// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTaskManagerUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTaskManagerUI",
            targets: ["CmuxTaskManagerUI"]
        ),
    ],
    dependencies: [
        // The Task Manager domain value types this package presents. The
        // `CmuxTaskManagerRow.Kind` presentation (SF Symbol + tint color)
        // lives here as an extension so the domain package stays SwiftUI-free.
        .package(path: "../CmuxTaskManager"),
    ],
    targets: [
        .target(
            name: "CmuxTaskManagerUI",
            dependencies: [
                .product(name: "CmuxTaskManager", package: "CmuxTaskManager"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTaskManagerUITests",
            dependencies: [
                "CmuxTaskManagerUI",
                .product(name: "CmuxTaskManager", package: "CmuxTaskManager"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
