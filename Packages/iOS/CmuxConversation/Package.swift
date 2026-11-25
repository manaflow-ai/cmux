// swift-tools-version: 6.0

import Foundation
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxConversation",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxConversationCore", targets: ["CmuxConversationCore"]),
        .library(name: "CmuxConversationUI", targets: ["CmuxConversationUI"]),
        // The bubble outline alone (CoreGraphics), for surfaces that draw a
        // transcript without the chat UI (the notification content extension).
        .library(name: "CmuxConversationGeometry", targets: ["CmuxConversationGeometry"]),
        .library(name: "CmuxConversationMacUI", targets: ["CmuxConversationMacUI"]),
    ],
    dependencies: [
        // The composer's keyboard dock (MobileKeyboardDock), iOS only.
        .package(path: "../CmuxMobileSupport"),
        // The spinner every cmux surface draws, on the shared spinner period.
        .package(path: "../../Shared/CmuxSpinner"),
    ],
    targets: [
        .target(
            name: "CmuxConversationCore",
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .target(name: "CmuxConversationGeometry", dependencies: ["CmuxConversationCore"], swiftSettings: swiftSettings),
        .target(
            name: "CmuxConversationTranslation",
            dependencies: ["CmuxConversationCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CmuxConversationUI",
            dependencies: [
                "CmuxConversationCore", "CmuxConversationGeometry", "CmuxConversationTranslation", .product(name: "CmuxSpinner", package: "CmuxSpinner"),
                .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CmuxConversationMacUI",
            dependencies: ["CmuxConversationCore", "CmuxConversationGeometry", "CmuxConversationTranslation", .product(name: "CmuxSpinner", package: "CmuxSpinner")],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "CmuxConversationLabMac",
            dependencies: ["CmuxConversationMacUI"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxConversationGeometryTests",
            dependencies: ["CmuxConversationGeometry"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxConversationCoreTests",
            dependencies: ["CmuxConversationCore", "CmuxConversationGeometry"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxConversationMacUITests",
            dependencies: ["CmuxConversationMacUI", "CmuxConversationCore"],
            swiftSettings: swiftSettings
        ),
    ]
)

#if os(Linux)
// Apple SDKs ship the SQLite3 module; a build for Linux takes it from the system library. Only the Linux
// package jobs (swift-linux-packages.yml) set CMUX_SWIFTPM_TARGET_LINUX; a build for an Apple platform
// on a Linux host (the fleet) keeps the SDK's module. CryptoKit is Apple-only too: the Linux build takes
// the same API from swift-crypto (`import Crypto`), so an Apple build resolves no remote package and
// this package keeps no Package.resolved (scripts/check-package-resolved-policy.py skips this block).
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.targets.append(
        .systemLibrary(
            name: "SQLite3",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        )
    )
    // The chat UI (UIKit, AppKit, SwiftUI) and the Translation framework are Apple only: the Linux build
    // keeps Core, Geometry and their tests, and needs neither local package (both feed only the UI).
    let appleOnly: Set<String> = [
        "CmuxConversationUI", "CmuxConversationMacUI", "CmuxConversationLabMac", "CmuxConversationTranslation",
        "CmuxConversationMacUITests",
    ]
    package.targets.removeAll { appleOnly.contains($0.name) }
    package.products.removeAll { appleOnly.contains($0.name) }
    package.dependencies.removeAll()
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    package.targets.first { $0.name == "CmuxConversationCore" }?.dependencies.append(contentsOf: [
        "SQLite3", .product(name: "Crypto", package: "swift-crypto"),
    ])
}
#endif
