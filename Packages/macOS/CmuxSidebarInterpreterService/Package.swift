// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSidebarInterpreterService",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        // Host-side client + wire protocol the app links against.
        .library(
            name: "CmuxSidebarInterpreterClient",
            targets: ["CmuxSidebarInterpreterClient"]
        ),
        // The out-of-process worker that runs the untrusted interpreter.
        .executable(
            name: "cmux-sidebar-interpreter",
            targets: ["cmux-sidebar-interpreter"]
        ),
        // Headless protocol fixture for RenderWorkerClient supervision tests.
        .executable(
            name: "cmux-sidebar-render-fixture",
            targets: ["cmux-sidebar-render-fixture"]
        ),
        // Remote rendering: the faceless render-worker loop and the host-side
        // layer-hosting sidebar surface.
        .library(
            name: "CmuxSidebarRemoteRender",
            targets: ["CmuxSidebarRemoteRender"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSwiftRender"),
        .package(path: "../CmuxSwiftRenderUI"),
    ],
    targets: [
        .target(
            name: "CmuxSidebarInterpreterClient",
            dependencies: ["CmuxSwiftRender"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "cmux-sidebar-interpreter",
            dependencies: ["CmuxSidebarInterpreterClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "cmux-sidebar-render-fixture",
            dependencies: ["CmuxSidebarInterpreterClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CmuxSidebarRemoteRender",
            dependencies: [
                "CmuxSidebarInterpreterClient",
                .product(name: "CmuxSwiftRenderUI", package: "CmuxSwiftRenderUI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxSidebarInterpreterClientTests",
            dependencies: ["CmuxSidebarInterpreterClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxSidebarRemoteRenderTests",
            dependencies: ["CmuxSidebarRemoteRender"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
