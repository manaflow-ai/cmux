// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryDirectory = packageDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let irohMacOSLibraryDirectory = repositoryDirectory
    .appending(path: "CmuxIrohFFI.xcframework/macos-arm64_x86_64").path

let package = Package(
    name: "CmuxMobileTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileTransport",
            targets: ["CmuxMobileTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxIrohC",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(
                    ["-L", irohMacOSLibraryDirectory],
                    .when(platforms: [.macOS])
                ),
                .linkedLibrary("cmux_iroh_ffi", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "CmuxMobileTransport",
            dependencies: ["CMUXMobileCore", "CmuxIrohC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileTransportTests",
            dependencies: ["CmuxMobileTransport", "CMUXMobileCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
