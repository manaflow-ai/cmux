// swift-tools-version: 6.0

import Foundation
import PackageDescription

let package = Package(
    name: "CmuxMobilePairedMac",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobilePairedMac",
            targets: ["CmuxMobilePairedMac"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxMobilePairedMac",
            dependencies: [
                "CMUXMobileCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobilePairedMacTests",
            dependencies: ["CmuxMobilePairedMac"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

#if os(Linux)
// Apple SDKs ship the SQLite3 module; a build for Linux takes it from the system library. Only the Linux
// package jobs (swift-packages-linux.yml) set CMUX_SWIFTPM_TARGET_LINUX; a build for an Apple platform
// on a Linux host (the fleet) keeps the SDK's module.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.targets.append(
        .systemLibrary(
            name: "SQLite3",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        )
    )
    package.targets.first { $0.name == "CmuxMobilePairedMac" }?.dependencies.append("SQLite3")
}
#endif
