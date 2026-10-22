// swift-tools-version: 6.0

import Foundation
import PackageDescription

let package = Package(
    name: "CmuxMobileRPC",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileRPC",
            targets: ["CmuxMobileRPC"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxTerminalSizing"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxMobileRPC",
            dependencies: [
                "CMUXMobileCore",
                "CmuxTerminalSizing",
                "CmuxMobileShellModel",
                "CmuxMobileSupport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileRPCTests",
            dependencies: [
                "CmuxMobileRPC",
                "CMUXMobileCore",
                "CmuxMobileShellModel",
                "CmuxTerminalSizing",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

#if os(Linux)
// CmuxMobileSupport's SwiftUI views do not build on Linux, and this target uses only its L10n lookup
// (L10n+Portable.swift stands in for it). Only the Linux package jobs (swift-packages-linux.yml) set
// CMUX_SWIFTPM_TARGET_LINUX; a build for an Apple platform on a Linux host (the fleet) keeps the package.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.removeAll {
        if case let .fileSystem(_, path) = $0.kind { return path.hasSuffix("/CmuxMobileSupport") }
        return false
    }
    for target in package.targets where target.name == "CmuxMobileRPC" {
        target.dependencies.removeAll {
            if case .byNameItem(name: "CmuxMobileSupport", _) = $0 { return true }
            return false
        }
    }
}
#endif
