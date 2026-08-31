// swift-tools-version: 6.0

import PackageDescription

// Development-only. Deliberately NOT wired into cmux.xcodeproj: it exists so
// sidebar UI can be iterated on in seconds by rendering to PNG, instead of
// paying a ~15 minute app build to look at a panel. Nothing ships from here.
let package = Package(
    name: "CmuxSidebarGallery",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../CmuxSidebar"),
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .executableTarget(
            name: "CmuxSidebarGallery",
            dependencies: [
                .product(name: "CmuxSidebar", package: "CmuxSidebar"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
