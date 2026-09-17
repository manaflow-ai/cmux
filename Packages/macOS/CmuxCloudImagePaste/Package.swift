// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCloudImagePaste",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxCloudImagePaste", targets: ["CmuxCloudImagePaste"]),
    ],
    targets: [
        .target(
            name: "CmuxCloudImagePaste",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCloudImagePasteTests",
            dependencies: ["CmuxCloudImagePaste"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
