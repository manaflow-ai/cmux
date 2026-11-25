// swift-tools-version: 6.0

import PackageDescription

// The one Chief list rule of every cmux Home (user 2026-11-17: "make sure that they both display the
// same exact chief list using the same exact mechanism"): which Chiefs are listed, which one is Main,
// where each runs, the tag after each name and the picker order. The Mac's Home (CmuxNextHomeModel's
// HomeChiefRoster) and the iPhone's Home (CmuxMobileChief) both call it; neither keeps a copy.
// Pure values, no dependencies, so both apps link it.
let package = Package(
    name: "CmuxChiefList",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxChiefList", targets: ["CmuxChiefList"]),
    ],
    targets: [
        .target(
            name: "CmuxChiefList",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxChiefListTests",
            dependencies: ["CmuxChiefList"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
