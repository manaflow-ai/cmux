// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAcpmux",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxAcpmux", targets: ["CmuxAcpmux"]),
    ],
    targets: [
        .target(
            name: "CmuxAcpmux",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CmuxAcpmuxTests",
            dependencies: ["CmuxAcpmux"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
