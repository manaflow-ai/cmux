// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxHive",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxHive", targets: ["CmuxHive"])],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../iOS/CmuxMobilePairedMac"),
        .package(path: "../../iOS/CmuxMobileRPC"),
        .package(path: "../../iOS/CmuxMobileTransport"),
    ],
    targets: [
        .target(name: "CmuxHive", dependencies: [
            "CMUXMobileCore",
            "CmuxMobilePairedMac", "CmuxMobileRPC", "CmuxMobileTransport",
        ], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxHiveTests", dependencies: [
            "CmuxHive", "CMUXMobileCore", "CmuxMobileRPC", "CmuxMobilePairedMac",
        ], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
