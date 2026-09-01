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
                "IshKernel",
            ],
            resources: [
                // Fetched by scripts/build-ish-ios.sh (gitignored); imported
                // into the persistent fakefs on first boot.
                .copy("Resources/alpine-rootfs.tar.gz"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
