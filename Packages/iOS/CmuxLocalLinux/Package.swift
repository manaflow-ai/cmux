// swift-tools-version: 6.0

import PackageDescription

// On-device minimal Linux (Alpine i386 userland) via the vendored iSH
// usermode-x86 emulator (vendor/ish, manaflow-ai/ish fork, GPLv3 with the
// iSH LICENSE.IOS App Store grant; cmux is GPL-3.0-or-later so the terms
// compose). `IshKernel.xcframework` is produced by scripts/build-ish-ios.sh
// and bundles libish + libish_emu + libfakefs + libarchive + the cmux shim.
let package = Package(
    name: "CmuxLocalLinux",
    platforms: [
        .iOS(.v18),
        // Keep the protocol, ring, and test seams buildable on the host. The
        // iSH bridge is conditionally compiled when the iOS module is present.
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxLocalLinux",
            targets: ["CmuxLocalLinux"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../CmuxMobileRPC"),
    ],
    targets: [
        .binaryTarget(
            name: "IshKernel",
            path: "../../../IshKernel.xcframework"
        ),
        .target(
            name: "CmuxLocalLinux",
            dependencies: [
                "CMUXMobileCore",
                "CmuxMobileRPC",
                // The generated binary contains iOS slices only. Keep the
                // protocol and test seams available to the macOS host without
                // asking SwiftPM to link an iOS archive there.
                .target(name: "IshKernel", condition: .when(platforms: [.iOS])),
            ],
            resources: [
                // Imported into the persistent fakefs on first boot. The
                // archive and its provenance are checked in so package
                // resolution does not depend on a network fetch.
                .copy("Resources/alpine-rootfs.tar.gz"),
                .copy("Resources/alpine-rootfs.json"),
                .copy("Resources/THIRD_PARTY_NOTICES.md"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // libarchive uses the system bzip2 implementation on iOS.
                .linkedLibrary("bz2", .when(platforms: [.iOS])),
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(
            name: "CmuxLocalLinuxTests",
            dependencies: ["CmuxLocalLinux"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
