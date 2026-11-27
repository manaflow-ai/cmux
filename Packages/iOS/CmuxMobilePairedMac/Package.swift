// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Linux lacks Apple-only APIs this package uses: CmuxLinuxCompat supplies
// the SQLite3 module and stand-ins (os Logger, `Darwin.`-qualified libc, String(localized:)).
// Apple builds never see this dependency.
#if os(Linux)
let packageDependencies: [Package.Dependency] = [
    .package(path: "../../Shared/CmuxLinuxCompat"),
]
let targetDependencies: [Target.Dependency] = [
    .product(name: "CmuxLinuxSQLite3", package: "CmuxLinuxCompat"),
    .product(name: "CmuxLinuxCompat", package: "CmuxLinuxCompat"),
]
#else
let packageDependencies: [Package.Dependency] = []
let targetDependencies: [Target.Dependency] = []
#endif

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
    dependencies: packageDependencies + [
        .package(path: "../../Shared/CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxMobilePairedMac",
            dependencies: targetDependencies + [
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
            dependencies: targetDependencies + ["CmuxMobilePairedMac"],
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
