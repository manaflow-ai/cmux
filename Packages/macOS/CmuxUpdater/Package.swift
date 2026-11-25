// swift-tools-version: 6.0

import Foundation
import PackageDescription

let linuxTarget = ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1"
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]
let coreTargets: [Target] = [
    .target(name: "CmuxUpdaterCore", swiftSettings: swiftSettings),
    .target(
        name: "CmuxUpdaterTestSupport",
        dependencies: ["CmuxUpdaterCore"],
        path: "Tests/CmuxUpdaterTestSupport",
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "CmuxUpdaterCoreTests",
        dependencies: ["CmuxUpdaterCore", "CmuxUpdaterTestSupport"],
        swiftSettings: swiftSettings
    ),
]
let appleTargets: [Target] = [
    .target(
        name: "CmuxUpdater",
        dependencies: ["CmuxUpdaterCore", .product(name: "Sparkle", package: "Sparkle")],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "CmuxUpdaterTests",
        dependencies: ["CmuxUpdater", "CmuxUpdaterTestSupport", .product(name: "Sparkle", package: "Sparkle")],
        swiftSettings: swiftSettings
    ),
]
let library = linuxTarget ? "CmuxUpdaterCore" : "CmuxUpdater"
let package = Package(
    name: "CmuxUpdater",
    platforms: [.macOS(.v14)],
    products: [.library(name: library, targets: [library])],
    dependencies: linuxTarget ? [] : [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")],
    targets: coreTargets + (linuxTarget ? [] : appleTargets)
)
