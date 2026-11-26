// swift-tools-version: 6.0

import Foundation
import PackageDescription

let package = Package(
    name: "CmuxMobileSSH",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileSSH",
            targets: ["CmuxMobileSSH"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxMobileTunnel"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "CmuxMobileSSH",
            dependencies: [
                "CmuxMobileTunnel",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileSSHTests",
            dependencies: [
                "CmuxMobileSSH",
                "CmuxMobileTunnel",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)

// Network.framework (NIOTransportServices) is Apple only; a build for Linux uses NIOPosix sockets.
// Only the Linux package jobs set CMUX_SWIFTPM_TARGET_LINUX, so a build for an Apple platform on a
// Linux host (the fleet) keeps the manifest above.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.targets.first { $0.name == "CmuxMobileSSH" }?.dependencies.append(
        .product(name: "NIOPosix", package: "swift-nio")
    )
}
