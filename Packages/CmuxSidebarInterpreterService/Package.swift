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
    ],
    dependencies: [
        .package(path: "../CmuxSwiftRender"),
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
        .testTarget(
            name: "CmuxSidebarInterpreterClientTests",
            dependencies: ["CmuxSidebarInterpreterClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
