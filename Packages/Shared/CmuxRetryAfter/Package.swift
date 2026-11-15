// swift-tools-version: 6.0

import PackageDescription

// `CmuxRetryAfter` reads a server's Retry-After directive (delta-seconds or an
// HTTP-date) and holds the shared cooldown. It is its own package so the Mac
// app's CmuxAuthRuntime links it without linking CMUXMobileCore, the iPhone
// core that re-exports it for the phone transports.
let package = Package(
    name: "CmuxRetryAfter",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxRetryAfter",
            targets: ["CmuxRetryAfter"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxRetryAfter",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxRetryAfterTests",
            dependencies: ["CmuxRetryAfter"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
