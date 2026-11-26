// swift-tools-version: 6.0

import Foundation
import PackageDescription

let package = Package(
    name: "CmuxAuthRuntime",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAuthRuntime",
            targets: ["CmuxAuthRuntime"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxEgress"),
        .package(path: "../CMUXAuthCore"),
        .package(path: "../../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "CmuxAuthRuntime",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CMUXAuthCore",
                .product(name: "CmuxEgress", package: "CmuxEgress"),
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAuthRuntimeTests",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxAuthRuntime",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)

#if os(Linux)
// Apple SDKs provide SQLite3 directly. The Linux package lane supplies the
// system module and installs its development headers in CI.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.targets.append(
        .systemLibrary(
            name: "SQLite3",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        )
    )
    package.targets.first { $0.name == "CmuxAuthRuntime" }?.dependencies.append("SQLite3")
}
#endif
