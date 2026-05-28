// swift-tools-version: 6.2

import PackageDescription

// CmuxSettingsUI is a SwiftUI / AppKit layer that always runs on the
// main actor. We default-isolate the whole package to `MainActor`
// instead of sprinkling `@MainActor` on every view, model, and section
// type.
let mainActorIsolation: [SwiftSetting] = [
    .defaultIsolation(MainActor.self)
]

let package = Package(
    name: "CmuxSettingsUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSettingsUI",
            targets: ["CmuxSettingsUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxSettingsUI",
            dependencies: [
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ],
            swiftSettings: mainActorIsolation
        ),
        .testTarget(
            name: "CmuxSettingsUITests",
            dependencies: ["CmuxSettingsUI"],
            swiftSettings: mainActorIsolation
        ),
    ]
)
