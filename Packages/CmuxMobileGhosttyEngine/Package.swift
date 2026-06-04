// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileGhosttyEngine",
    platforms: [
        .iOS(.v18),
        // macOS so the session/registry logic (which never touches UIKit)
        // is exercisable with `swift test` without booting a simulator.
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileGhosttyEngine",
            targets: ["CmuxMobileGhosttyEngine"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxMobileDiagnostics"),
    ],
    targets: [
        // The same libghostty the Mac links; iOS feeds raw PTY bytes straight
        // into ghostty_surface_* so the phone runs the identical terminal
        // core. This package is the single owner of the binary target — all
        // blocking libghostty calls live behind its actors.
        .binaryTarget(
            name: "GhosttyKit",
            path: "../../GhosttyKit.xcframework"
        ),
        .target(
            name: "CmuxMobileGhosttyEngine",
            dependencies: [
                "CmuxMobileDiagnostics",
                // iOS-only: SwiftPM cannot consume the xcframework's macOS
                // slice (its static archive is not lib-prefixed), and the
                // macOS build exists purely so `swift test` can exercise the
                // session/registry logic, which never touches libghostty.
                .target(name: "GhosttyKit", condition: .when(platforms: [.iOS])),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileGhosttyEngineTests",
            dependencies: ["CmuxMobileGhosttyEngine"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
