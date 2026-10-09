// swift-tools-version: 6.0
import PackageDescription

// D2 bakeoff harness (plans/cmux-next/ios-next/d2-bakeoff.md): drives any
// CmuxLink carrier and acceptor pair (V1 webrtc, V2 webrtc-wg, V3 direct, the
// A3 loopback reference) through the same workloads and writes JSON results.
// The library is also linked by the DEBUG-only iOS Link bench client. The
// executable remains a macOS development tool and is never shipped.
let package = Package(
    name: "CmuxLinkBench",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxLinkBench", targets: ["CmuxLinkBench"]),
        .executable(name: "cmux-link-bench", targets: ["cmux-link-bench"]),
    ],
    dependencies: [
        .package(path: "../CmuxLink"),
        .package(path: "../CmuxLinkWG"),
        .package(path: "../CmuxLinkWebRTC"),
        .package(path: "../CmuxLinkDirect"),
    ],
    targets: [
        .target(
            name: "CmuxLinkBench",
            dependencies: [
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
                .product(name: "CmuxLinkSignaling", package: "CmuxLink"),
                .product(name: "CmuxLinkWG", package: "CmuxLinkWG"),
                .product(name: "CmuxLinkWGTesting", package: "CmuxLinkWG"),
                .product(name: "CmuxLinkWebRTC", package: "CmuxLinkWebRTC"),
                .product(name: "CmuxLinkWebRTCUnderlay", package: "CmuxLinkWebRTC"),
                .product(name: "CmuxLinkDirect", package: "CmuxLinkDirect"),
            ]
        ),
        .executableTarget(name: "cmux-link-bench", dependencies: [
            "CmuxLinkBench", .product(name: "CmuxLinkDirect", package: "CmuxLinkDirect"),
        ]),
        .testTarget(name: "CmuxLinkBenchTests", dependencies: [
            "CmuxLinkBench", .product(name: "CmuxLinkDirect", package: "CmuxLinkDirect"),
            .product(name: "CmuxLink", package: "CmuxLink"),
            .product(name: "CmuxLinkSignaling", package: "CmuxLink"),
            .product(name: "CmuxLinkWebRTC", package: "CmuxLinkWebRTC"),
            .product(name: "CmuxLinkWG", package: "CmuxLinkWG"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
