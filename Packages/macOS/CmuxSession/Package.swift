// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSession",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSession",
            targets: ["CmuxSession"]
        ),
    ],
    dependencies: [
        // CmuxSession reuses the EXISTING CmuxWorkspaces session seams
        // (SessionSnapshotRepresenting, WindowGeometryPersisting,
        // SessionSnapshotStoring, WindowGeometryStore, SessionSnapshotPersistor,
        // SessionAutosaveScheduler, SessionPersistenceDecisionPolicy,
        // SessionSnapshotBuilder, SessionLifecycleObserver, …) rather than
        // minting parallel ones. It composes those into the app-facing
        // AppSessionCoordinator orchestration.
        .package(path: "../CmuxWorkspaces"),
        // CMUXDebugLog backs the orchestration's DEBUG save/restore breadcrumbs,
        // matching the legacy in-file `cmuxDebugLog` calls.
        .package(path: "../CMUXDebugLog"),
    ],
    targets: [
        .target(
            name: "CmuxSession",
            dependencies: [
                .product(name: "CmuxWorkspaces", package: "CmuxWorkspaces"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        // Test-only stand-in for the @_silgen_name libghostty symbols bound
        // transitively through CmuxWorkspaces -> CmuxTerminalCore. SwiftPM
        // cannot link the GhosttyKit macOS archive (its binary lacks the lib
        // prefix), so the test runner satisfies the link with this stub; no
        // test calls it. The app build links the real GhosttyKit. Mirrors
        // CmuxWorkspaces' own GhosttyRuntimeTestStubs target.
        .target(
            name: "GhosttyRuntimeTestStubs",
            path: "Tests/GhosttyRuntimeTestStubs"
        ),
        .testTarget(
            name: "CmuxSessionTests",
            dependencies: [
                "CmuxSession",
                "GhosttyRuntimeTestStubs",
                .product(name: "CmuxWorkspaces", package: "CmuxWorkspaces"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
