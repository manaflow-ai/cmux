// swift-tools-version: 6.2
import PackageDescription

// A separate test root keeps capture builds out of the app's unrelated test targets.
let package = Package(
    name: "CmuxNativeSidebarGallery",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../CmuxNext"),
        .package(path: "../../Shared/CmuxTheme"),
    ],
    targets: [
        .testTarget(
            name: "CmuxNativeSidebarGalleryTests",
            dependencies: [
                .product(name: "CmuxNextNativeGallerySupport", package: "CmuxNext"),
                .product(name: "CmuxTheme", package: "CmuxTheme"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
