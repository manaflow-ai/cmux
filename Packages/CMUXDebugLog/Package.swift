// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CMUXDebugLog",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CMUXDebugLog",
            targets: ["CMUXDebugLog"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXDebugLog",
            path: "Sources/CMUXDebugLog",
            // Bumped tools-version to 6.2 with the rest of the packages, but pin
            // the Swift 5 language mode this package has always built under: its
            // shared DebugEventLog singleton is not Swift 6 strict-concurrency
            // clean, and modernizing it is separate from the version bump.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CMUXDebugLogTests",
            dependencies: ["CMUXDebugLog"],
            path: "Tests/CMUXDebugLogTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
