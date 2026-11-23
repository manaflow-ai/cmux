// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The phone's mobile-sync RPC client: wire DTOs, the multiplexed session and
// its transport lifecycle. It needs only Foundation and the shared mobile
// core, so its tests also run on Linux (scripts/ci/swift-linux-packages.txt).
// Its CmuxMobileSupport dependency is a UIKit package used here only for
// `L10n.string`, so the Linux package jobs, which set
// CMUX_SWIFTPM_TARGET_LINUX, leave that dependency out and the target
// compiles a Foundation-only stand-in (L10n+WithoutMobileSupport.swift). A
// build for an Apple platform on a Linux host keeps it.
#if os(Linux)
let targetsLinux = ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1"
#else
let targetsLinux = false
#endif

let package = Package(
    name: "CmuxMobileRPC",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileRPC",
            targets: ["CmuxMobileRPC"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxTerminalSizing"),
        .package(path: "../CmuxMobileShellModel"),
    ] + (targetsLinux ? [] : [
        .package(path: "../CmuxMobileSupport"),
    ]),
    targets: [
        .target(
            name: "CmuxMobileRPC",
            dependencies: [
                "CMUXMobileCore",
                "CmuxTerminalSizing",
                "CmuxMobileShellModel",
            ] + (targetsLinux ? [] : [
                "CmuxMobileSupport",
            ]),
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileRPCTests",
            dependencies: [
                "CmuxMobileRPC",
                "CMUXMobileCore",
                "CmuxMobileShellModel",
                "CmuxTerminalSizing",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
