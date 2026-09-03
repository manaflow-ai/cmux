// swift-tools-version: 6.0

import PackageDescription

// On-device minimal Linux (Alpine i386 userland) via the vendored iSH
// usermode-x86 emulator (vendor/ish, manaflow-ai/ish fork, GPLv3 with the
// iSH LICENSE.IOS App Store grant; cmux is GPL-3.0-or-later so the terms
// compose). `IshKernel.xcframework` is produced by scripts/build-ish-ios.sh
// and contains the static iSH libraries, libarchive, and the cmux shim.
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
            name: "IshKernelBinary",
            path: "../../../IshKernel.xcframework"
        ),
        // Keep the C declarations in a normal SwiftPM target. The binary
        // archive intentionally has no headers: Xcode copies binary-target
        // module maps to a shared include/module.modulemap path, which
        // collides with GhosttyKit. This target supplies the module without
        // embedding a second binary framework or module-map product.
        .target(
            name: "CmuxIshBridge",
            dependencies: [
                .target(name: "IshKernelBinary", condition: .when(platforms: [.iOS])),
            ],
            path: "ShimSource",
            exclude: ["cmux_ish.c"],
            publicHeadersPath: "."
        ),
        .target(
            name: "CmuxLocalLinux",
            dependencies: [
                "CMUXMobileCore",
                "CmuxMobileRPC",
                "CmuxIshBridge",
            ],
            resources: [
                // Imported into the persistent fakefs on first boot. The
                // archive and its provenance are checked in so package
                // resolution does not depend on a network fetch.
                .copy("Resources/alpine-rootfs.tar.gz"),
                .copy("Resources/alpine-rootfs.json"),
                .copy("Resources/THIRD_PARTY_NOTICES.md"),
                .copy("Resources/iSH-LICENSE.md"),
                .copy("Resources/iSH-LICENSE.IOS"),
                .copy("Resources/GPL-2.0.txt"),
                .copy("Resources/GPL-3.0.txt"),
                .copy("Resources/libarchive-COPYING"),
                .copy("Resources/SOURCE-OFFER.md"),
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
