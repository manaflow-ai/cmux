// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaces",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaces",
            targets: ["CmuxWorkspaces"]
        ),
    ],
    dependencies: [
        // CmuxFoundation owns WorkspaceMountPlan, the pure mount-priority value
        // the Handoff/ coordinator computes its mounted set from.
        .package(path: "../CmuxFoundation"),
        // CmuxCore owns the WorkspaceRemote* value types carried by
        // SelectedWorkspaceDirectorySnapshot.
        .package(path: "../CmuxCore"),
        // WorkspaceGroupNewPlacement (the typed setting value for new
        // in-group workspace placement) is owned by CmuxSettings.
        .package(path: "../CmuxSettings"),
        // Bonsplit drives the Window/ tmux pane-overlay geometry.
        .package(path: "../../../vendor/bonsplit"),
        // CmuxPanes owns the split-tree geometry recursions
        // (browserPathToPane/browserCollectPaneNodes/
        // browserCollectNormalizedPaneBounds/splitIdJoiningPanes) the
        // SurfaceLifecycle/ resolvers compute over.
        .package(path: "../CmuxPanes"),
        // CMUXDebugLog backs the Session/ snapshot-restore logging.
        .package(path: "../CMUXDebugLog"),
        // CmuxTestSupport backs FileOpen/ PreferredEditorService UI-test capture.
        .package(path: "../CmuxTestSupport"),
        // SessionDisplayGeometry (the live-screen geometry value the session
        // frame resolver reads) is owned by CmuxWindowing.
        .package(path: "../CmuxWindowing"),
        // CmuxSurfaceConfigTemplate (the Sendable inherited-surface config the
        // SurfaceCreation/ coordinator promotes for wait-after-command) is owned
        // by CmuxTerminalCore.
        .package(path: "../CmuxTerminalCore"),
        // CmuxSSHURLRequest (the validated `cmux ssh` deep link the SSHURL/
        // launch service expands into a `cmux ssh` argument vector) is owned by
        // CmuxRemoteWorkspace.
        .package(path: "../CmuxRemoteWorkspace"),
        // TerminalStartupWorkingDirectoryPrefix / TerminalStartupReturnShellScript
        // (the cd-prefix rewriting and command-then-return-to-login-shell line
        // builders) used by SurfaceResumeBindingSnapshot's launcher-script path
        // are owned by CMUXAgentLaunch.
        .package(path: "../CMUXAgentLaunch"),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaces",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CmuxPanes", package: "CmuxPanes"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
                .product(name: "CmuxWindowing", package: "CmuxWindowing"),
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(name: "CmuxRemoteWorkspace", package: "CmuxRemoteWorkspace"),
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            // Transitively links GhosttyKit (via CmuxTerminalCore), whose static
            // archive carries C++ objects. When realized as a dynamic
            // PackageProduct.framework the link must resolve those std:: symbols
            // itself. See the matching note in CmuxTerminalCore's Package.swift.
            // Harmless when static.
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        // Test-only stand-in for the @_silgen_name libghostty symbols bound by
        // CmuxTerminalCore (which CmuxWorkspaces now depends on). SwiftPM cannot
        // link the GhosttyKit macOS archive (its binary lacks the lib prefix), so
        // the test runner satisfies the link with this stub; no test calls it.
        // The app build links the real GhosttyKit. Mirrors CmuxTerminalCore's own
        // GhosttyRuntimeTestStubs target.
        .target(
            name: "GhosttyRuntimeTestStubs",
            path: "Tests/GhosttyRuntimeTestStubs"
        ),
        .testTarget(
            name: "CmuxWorkspacesTests",
            dependencies: [
                "CmuxWorkspaces",
                "GhosttyRuntimeTestStubs",
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CmuxPanes", package: "CmuxPanes"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
                .product(name: "CmuxWindowing", package: "CmuxWindowing"),
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(name: "CmuxRemoteWorkspace", package: "CmuxRemoteWorkspace"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
