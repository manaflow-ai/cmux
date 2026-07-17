// swift-tools-version: 6.0

import PackageDescription

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
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxSettingsUI",
            dependencies: [
                "CMUXMobileCore",
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ],
            // macOS 26.4.x has a Swift runtime bug where the dynamic executor
            // check emitted by -enable-actor-data-race-checks (Xcode's Debug
            // default) SEGVs inside swift_task_isCurrentExecutor. It fires in
            // LiveSetting's @preconcurrency DynamicProperty.update() witness the
            // moment any SwiftUI view with an @LiveSetting renders, crashing the
            // Debug app at launch. Release builds omit the check (which is why
            // release is unaffected); disable it for Debug here so the Debug
            // build matches release and stops crashing. Debug-scoped only.
            swiftSettings: [
                .unsafeFlags(["-disable-actor-data-race-checks"], .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "CmuxSettingsUITests",
            dependencies: ["CmuxSettingsUI"]
        ),
    ]
)
