// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxCEF",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCEF",
            targets: ["CmuxCEF"]
        ),
    ],
    targets: [
        // Objective-C bridge to the dynamically loaded CEF framework. The
        // pinned CEF headers are vendored under `cef/` so struct layouts are
        // compiled against the exact revision scripts/ensure-cef.sh installs.
        .target(
            name: "CmuxCEFShim",
            path: "Sources/CmuxCEFShim",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("cef"),
            ],
            linkerSettings: [
                // CEF symbols resolve at runtime after the shim dlopens the
                // framework; nothing links against it directly.
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
                .linkedFramework("Cocoa"),
            ]
        ),
        .target(
            name: "CmuxCEF",
            dependencies: ["CmuxCEFShim"],
            path: "Sources/CmuxCEF",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCEFTests",
            dependencies: ["CmuxCEF"],
            path: "Tests/CmuxCEFTests"
        ),
    ]
)
