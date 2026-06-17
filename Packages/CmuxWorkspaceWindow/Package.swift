// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaceWindow",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaceWindow",
            targets: ["CmuxWorkspaceWindow"]
        ),
    ],
    dependencies: [
        .package(path: "../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaceWindow",
            dependencies: [
                .product(name: "Bonsplit", package: "bonsplit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorkspaceWindowTests",
            dependencies: [
                "CmuxWorkspaceWindow",
                .product(name: "Bonsplit", package: "bonsplit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
