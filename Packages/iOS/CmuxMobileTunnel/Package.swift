// swift-tools-version: 6.0

import Foundation
import PackageDescription

/// The phone's browser tunnel plumbing, independent of what carries the
/// bytes: a SOCKS5 proxy and loopback port forwards on the phone whose
/// connections are opened by a `SocksConnectBackend` (SSH `direct-tcpip`,
/// a paired Mac's irx lanes, or the phone's own network).
let package = Package(
    name: "CmuxMobileTunnel",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileTunnel",
            targets: ["CmuxMobileTunnel"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.23.0"),
    ],
    targets: [
        .target(
            name: "CmuxMobileTunnel",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileTunnelTests",
            dependencies: [
                "CmuxMobileTunnel",
                .product(name: "NIOCore", package: "swift-nio"),
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
    package.targets.first { $0.name == "CmuxMobileTunnel" }?.dependencies.append(
        .product(name: "NIOPosix", package: "swift-nio")
    )
}
