// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileDiffViewer",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileDiffViewer",
            targets: ["CmuxMobileDiffViewer"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxMobileDiffViewer",
            dependencies: [
                "CmuxMobileShellModel",
                "CmuxMobileSupport",
            ],
            resources: [
                // The diff-viewer React bundle, copied verbatim so the custom
                // URL scheme can serve the host HTML + every chunk + the
                // vendored `@pierre/diffs` worker assets under one origin. The
                // directory layout mirrors what the desktop CLI lays out next to
                // the generated viewer page (`ensureDiffViewerAssets`), so the
                // generated config's `assets.*ModuleURL` resolve unchanged.
                .copy("DiffViewerBundle"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileDiffViewerTests",
            dependencies: ["CmuxMobileDiffViewer"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
