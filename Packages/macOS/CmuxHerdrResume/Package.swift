// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxHerdrResume",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxHerdrResume",
            targets: ["CmuxHerdrResume"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxHerdrResume",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxHerdrResumeTests",
            dependencies: ["CmuxHerdrResume"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
