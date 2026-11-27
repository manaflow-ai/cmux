// swift-tools-version: 6.0

import Foundation
import PackageDescription

let package = Package(
    name: "CmuxPhonePush",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxPhonePush", targets: ["CmuxPhonePush"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxAuthRuntime"),
    ],
    targets: [
        .target(
            name: "CmuxPhonePush",
            dependencies: ["CmuxAuthRuntime"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxPhonePushTests",
            dependencies: ["CmuxPhonePush"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

#if os(Linux)
// CryptoKit is Apple-only: a build for Linux takes the same API from swift-crypto (`import Crypto`), as
// CmuxFeedPushCore does. Only the Linux package jobs (swift-linux-packages.yml) set
// CMUX_SWIFTPM_TARGET_LINUX; a build for an Apple platform keeps CryptoKit and resolves no remote package.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    for name in ["CmuxPhonePush", "CmuxPhonePushTests"] {
        package.targets.first { $0.name == name }?.dependencies.append(
            .product(name: "Crypto", package: "swift-crypto")
        )
    }
}
#endif
